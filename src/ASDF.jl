module ASDF

using ChunkCodecLibBlosc: BloscCodec, BloscEncodeOptions
using ChunkCodecLibBzip2: BZ2Codec, BZ2EncodeOptions
using ChunkCodecLibLz4: LZ4BlockCodec, LZ4FrameCodec, LZ4BlockEncodeOptions, LZ4FrameEncodeOptions
using ChunkCodecLibZlib: ZlibCodec, ZlibEncodeOptions
using ChunkCodecLibZstd: ZstdCodec, ZstdEncodeOptions, decode, encode
using CodecXz: XzCompressor, XzDecompressor
using MD5: md5
using PkgVersion: PkgVersion
using StridedViews: StridedView
using YAML: YAML
using OrderedCollections: OrderedDict
using FileIO: @format_str, File, load, save
using AbstractTrees: AbstractTrees

export load, save

################################################################################

const software_name = "ASDF.jl"
const software_author = PkgVersion.@Author "Erik Schnetter <schnetter@gmail.com>"
const software_homepage = "https://github.com/JuliaAstro/ASDF.jl"
const software_version = string(PkgVersion.@Version)

################################################################################

@enum Compression C_None C_Blosc C_Blosc2 C_Bzip2 C_Lz4 C_Xz C_Zlib C_Zstd

const compression_keys = Dict{Compression,Vector{UInt8}}(
    C_None => UInt8[0, 0, 0, 0],
    C_Blosc => Vector{UInt8}("blsc"),
    C_Blosc2 => Vector{UInt8}("bls2"),
    C_Bzip2 => Vector{UInt8}("bzp2"),
    C_Lz4 => Vector{UInt8}("lz4\0"),
    C_Xz => Vector{UInt8}("xz\0\0"),
    C_Zlib => Vector{UInt8}("zlib"),
    C_Zstd => Vector{UInt8}("zstd"),
)
if !all(length(val)==4 for val in values(compression_keys))
    error("Invalid entry in `compression_keys`, please ensure all values have length 4.")
end
const compression_enums = Dict{Vector{UInt8},Compression}(
    value => key for (key, value) in compression_keys
)

################################################################################

struct BlockHeader
    io::IO
    position::Int64

    token::AbstractVector{UInt8} # length 4
    header_size::UInt16
    flags::UInt32
    compression::AbstractVector{UInt8} # length 4
    allocated_size::UInt64
    used_size::UInt64
    data_size::UInt64
    checksum::AbstractVector{UInt8} # length 16
    validate_checksum::Bool
end

mutable struct LazyBlockHeaders
    block_headers::Vector{BlockHeader}
    LazyBlockHeaders() = new(BlockHeader[])
end

const block_magic_token = UInt8[0xd3, 0x42, 0x4c, 0x4b] # "\323BLK"

find_first_block(io::IO) = find_next_block(io, Int64(0))
function find_next_block(io::IO, pos::Int64)
    sz = 10 * 1000 * 1000
    buffer = Array{UInt8}(undef, sz)

    block_range = nothing
    while true
        seek(io, pos)
        nb = readbytes!(io, buffer)
        block_range = blockstart = findfirst(block_magic_token, @view buffer[1:(nb - 1)])
        block_range !== nothing && break
        did_reach_eof = eof(io)
        if did_reach_eof
            # We found nothing
            return nothing
        end
        pos += nb - (length(block_magic_token) - 1)
    end

    # Found a block header
    block_start = pos + first(block_range) - 1
    return block_start
end

big2native_U8(bytes::AbstractVector{UInt8}) = bytes[1]
big2native_U16(bytes::AbstractVector{UInt8}) = (UInt16(bytes[1]) << 8) | bytes[2]
big2native_U32(bytes::AbstractVector{UInt8}) = (UInt32(big2native_U16(@view bytes[1:2])) << 16) | big2native_U16(@view bytes[3:4])
big2native_U64(bytes::AbstractVector{UInt8}) = (UInt64(big2native_U32(@view bytes[1:4])) << 32) | big2native_U32(@view bytes[5:8])
# Read a 4-byte little-endian UInt32 (used for lz4.block store_size prefix)
little2native_U32(bytes::AbstractVector{UInt8}) = (UInt32(bytes[1])) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)

native2big_U8(val::UInt8) = UInt8[val]
native2big_U16(val::UInt16) = UInt8[(val >>> 0x08) & 0xff, (val >>> 0x00) & 0xff]
native2big_U32(val::UInt32) = UInt8[(val >>> 0x18) & 0xff, (val >>> 0x10) & 0xff, (val >>> 0x08) & 0xff, (val >>> 0x00) & 0xff]
function native2big_U64(val::UInt64)
    UInt8[
        (val >>> 0x38) & 0xff,
        (val >>> 0x30) & 0xff,
        (val >>> 0x28) & 0xff,
        (val >>> 0x20) & 0xff,
        (val >>> 0x18) & 0xff,
        (val >>> 0x10) & 0xff,
        (val >>> 0x08) & 0xff,
        (val >>> 0x00) & 0xff,
    ]
end
native2big_U8(val::Integer) = native2big_U8(UInt8(val))
native2big_U16(val::Integer) = native2big_U16(UInt16(val))
native2big_U32(val::Integer) = native2big_U32(UInt32(val))
native2big_U64(val::Integer) = native2big_U64(UInt64(val))

function read_block_header(io::IO, position::Int64; validate_checksum::Bool)
    # Read block header
    max_header_size = 6 + 48
    header = Array{UInt8}(undef, max_header_size)
    seek(io, position)
    nb = readbytes!(io, header)
    if nb != length(header)
        error("Number of bytes read from stream does not match length of header")
    end

    # Decode block header
    token = @view header[1:4]
    header_size = big2native_U16(@view header[5:6])
    flags = big2native_U32(@view header[7:10])
    compression = @view header[11:14]
    allocated_size = big2native_U64(@view header[15:22])
    used_size = big2native_U64(@view header[23:30])
    data_size = big2native_U64(@view header[31:38])
    checksum = @view header[39:54]

    if token != block_magic_token
        error("Block does not start with magic number")
    end

    STREAMED = Bool(flags & 0x1)
    # We don't handle streamed blocks yet
    if STREAMED
        error("ASDF.jl does not yet support streamed blocks")
    end

    if allocated_size < used_size
        error("ASDF file header incorrectly specifies amount of space to use")
    end

    return BlockHeader(io, position, token, header_size, flags, compression, allocated_size, used_size, data_size, checksum, validate_checksum)
end

function find_all_blocks(io::IO, pos::Int64=Int64(0); validate_checksum::Bool)
    headers = BlockHeader[]
    pos = find_next_block(io, pos)
    while pos !== nothing
        header = read_block_header(io, pos; validate_checksum)
        push!(headers, header)
        pos = Int64(header.position + 6 + header.header_size + header.allocated_size)
        pos = find_next_block(io, pos)
    end
    return headers
end

function read_block(header::BlockHeader)
    block_data_start = header.position + 6 + header.header_size
    seek(header.io, block_data_start)
    data = Array{UInt8}(undef, header.used_size)
    nb = readbytes!(header.io, data)
    if nb != length(data)
        error("Number of bytes read from `header` does not match length of `data`")
    end

    # Check checksum
    if header.validate_checksum && any(!iszero, header.checksum)
        actual_checksum = md5(data)
        if any(actual_checksum != header.checksum)
            error("Checksum mismatch in ASDF file header")
        end
    end

    # Decompress data
    # TODO: Read directly from file
    compression = compression_enums[header.compression]
    if compression == C_None
        # do nothing, the block is uncompressed
    elseif compression == C_Xz
        data = transcode(XzDecompressor, data)
    elseif compression == C_Lz4
        data = decode_Lz4(data)
    else
        if compression == C_Blosc
            codec = BloscCodec()
        elseif compression == C_Bzip2
            codec = BZ2Codec()
        elseif compression == C_Zlib
            codec = ZlibCodec()
        elseif compression == C_Zstd
            codec = ZstdCodec()
        else
            error("Invalid compression format found: $compression")
        end
        data = decode(codec, data)
    end
    data::AbstractVector{UInt8}

    if length(data) != header.data_size
        error("Actual data size different from declared data size in header.")
    end

    return data
end

function decode_Lz4(data)
    if (# LZ4 Frame magic bytes 04 22 4D 18
        length(data) >= 4 &&
        data[1] == 0x04 && data[2] == 0x22 &&
        data[3] == 0x4D && data[4] == 0x18)
        return decode(LZ4FrameCodec(), data)
    else
        # If the data was originally created from Python's ASDF, then it will be in block instead of frame layout,
        # where each chunk is:
        #
        #   [4 bytes, big-endian]    compressed chunk size (the ASDF envelope)
        #   [4 bytes, little-endian] uncompressed chunk size (lz4.block store_size=True prefix)
        #   [N bytes]                raw LZ4 block payload
        #
        # lz4.block.compress() defaults to store_size=True, which prepends the
        # uncompressed size as a little-endian uint32. LZ4BlockCodec expects only
        # the raw block, so both the outer BE envelope and the inner LE prefix must
        # be stripped, with the LE value used as the uncompressed_size hint.

        out = UInt8[]
        pos = 1

        while pos <= length(data)
            # Outer ASDF envelope: big-endian compressed chunk size
            compressed_chunk_size = Int(big2native_U32(@view data[pos:pos+3]))
            pos += 4
            # Inner lz4.block store_size=True prefix: little-endian uncompressed size
            uncompressed_chunk_size = Int(little2native_U32(@view data[pos:pos+3]))
            pos += 4
            # Raw LZ4 block payload (compressed_chunk_size includes the 4-byte LE prefix)
            payload_len = compressed_chunk_size - 4
            payload = @view data[pos:pos+payload_len-1]
            pos += payload_len
            append!(out, decode(LZ4BlockCodec(), payload; max_size = uncompressed_chunk_size, size_hint = uncompressed_chunk_size))
        end

        return out
    end
end

################################################################################

"""
    @enum ASDF.Byteorder Byteorder_little Byteorder_big
"""
@enum Byteorder Byteorder_little Byteorder_big
const byteorder_string_dict = Dict{Byteorder,String}(Byteorder_little => "little", Byteorder_big => "big")
const string_byteorder_dict = Dict{String,Byteorder}(val => key for (key, val) in byteorder_string_dict)

"""
    ASDF.Byteorder(str::AbstractString)::Byteorder
"""
Byteorder(str::AbstractString) = string_byteorder_dict[str]

"""
    string(byteorder::Byteorder)::AbstractString
"""
Base.string(byteorder::Byteorder) = byteorder_string_dict[byteorder]
Base.show(io::IO, byteorder::Byteorder) = show(io, string(byteorder))

const host_byteorder = reinterpret(UInt8, UInt16[1])[1] == 1 ? Byteorder_little : Byteorder_big

################################################################################

"""
Careful, there is also `Base.DataType`, which is a different type.
"""
@enum Datatype begin
    Datatype_bool8
    Datatype_int8
    Datatype_int16
    Datatype_int32
    Datatype_int64
    Datatype_int128
    Datatype_uint8
    Datatype_uint16
    Datatype_uint32
    Datatype_uint64
    Datatype_uint128
    Datatype_float16
    Datatype_float32
    Datatype_float64
    Datatype_complex32
    Datatype_complex64
    Datatype_complex128
end
const datatype_string_dict = Dict{Datatype,String}(
    Datatype_bool8 => "bool8",
    Datatype_int8 => "int8",
    Datatype_int16 => "int16",
    Datatype_int32 => "int32",
    Datatype_int64 => "int64",
    Datatype_int128 => "int128",
    Datatype_uint8 => "uint8",
    Datatype_uint16 => "uint16",
    Datatype_uint32 => "uint32",
    Datatype_uint64 => "uint64",
    Datatype_uint128 => "uint128",
    Datatype_float16 => "float16",
    Datatype_float32 => "float32",
    Datatype_float64 => "float64",
    Datatype_complex32 => "complex32",
    Datatype_complex64 => "complex64",
    Datatype_complex128 => "complex128",
)
const string_datatype_dict = Dict{String,Datatype}(val => key for (key, val) in datatype_string_dict)
const datatype_type_dict = Dict{Datatype,Type}(
    Datatype_bool8 => Bool,
    Datatype_int8 => Int8,
    Datatype_int16 => Int16,
    Datatype_int32 => Int32,
    Datatype_int64 => Int64,
    Datatype_int128 => Int128,
    Datatype_uint8 => UInt8,
    Datatype_uint16 => UInt16,
    Datatype_uint32 => UInt32,
    Datatype_uint64 => UInt64,
    Datatype_uint128 => UInt128,
    Datatype_float16 => Float16,
    Datatype_float32 => Float32,
    Datatype_float64 => Float64,
    Datatype_complex32 => Complex{Float16},
    Datatype_complex64 => Complex{Float32},
    Datatype_complex128 => Complex{Float64},
)
const type_datatype_dict = Dict{Type,Datatype}(val => key for (key, val) in datatype_type_dict)

Datatype(str::AbstractString) = string_datatype_dict[str]
Base.string(datatype::Datatype) = datatype_string_dict[datatype]
Base.show(io::IO, datatype::Datatype) = show(io, string(datatype))

Base.Type(datatype::Datatype) = datatype_type_dict[datatype]
Datatype(type::Type) = type_datatype_dict[type]

################################################################################

struct NDArray
    lazy_block_headers::LazyBlockHeaders

    source::Union{Nothing,Int64,AbstractString}
    data::Union{Nothing,AbstractArray}
    shape::Vector{Int64}
    datatype::Datatype
    byteorder::Byteorder
    offset::Int64
    strides::Vector{Int64} # stored in ASDF (Python/C) order, not in Julia (Fortran) order
    # mask

    function NDArray(
        lazy_block_headers::LazyBlockHeaders,
        source::Union{Nothing,Int64,AbstractString},
        data::Union{Nothing,AbstractArray},
        shape::Vector{Int64},
        datatype::Datatype,
        byteorder::Byteorder,
        offset::Int64,
        strides::Vector{Int64},
    )
        if (source === nothing) + (data === nothing) != 1
            throw(ArgumentError("Exactly one of `source` or `data` must be provided."))
        end
        if source !== nothing && source < 0
            throw(ArgumentError("`source` must be >= 0 if provided."))
        end
        if data !== nothing
            if eltype(data) != Type(datatype)
                throw(ArgumentError("`data` must contain elements of type given by `datatype`."))
            end
            if size(data) != Tuple(reverse(shape))
                throw(ArgumentError("`shape` does not correctly describe the shape of `data`."))
            end
        end
        if offset < 0
            throw(ArgumentError("`offset` must be >= 0."))
        end
        if length(shape) != length(strides)
            throw(DimensionMismatch("`shape` and `strides` must have the same length."))
        end
        if any(shape .< 0)
            throw(ArgumentError("`shape` cannot have negative elements."))
        end
        if !all(strides .> 0)
            throw(ArgumentError("`strides` must have only positive elements."))
        end
        return new(lazy_block_headers, source, data, shape, datatype, byteorder, offset, strides)
    end
end

function NDArray(
    lazy_block_headers::LazyBlockHeaders,
    source::Union{Nothing,Integer},
    data::Union{Nothing,AbstractArray},
    shape::AbstractVector{<:Integer},
    datatype::Union{Datatype,AbstractString},
    byteorder::Union{Nothing,Byteorder,AbstractString},
    offset::Union{Nothing,Integer}=0,
    strides::Union{Nothing,<:AbstractVector{<:Integer}}=nothing,
)
    if source isa Integer
        source = Int64(source)
    end
    if datatype isa AbstractString
        datatype = Datatype(datatype)
    end
    if data !== nothing
        # Convert arrays of arrays into multi-dimensional arrays
        data = stack(data)
        data = reshape(data, Tuple(reverse(shape)))
        # Correct element type
        data = Array{Type(datatype)}(data)
    end
    if byteorder isa Nothing
        byteorder = host_byteorder
    elseif byteorder isa AbstractString
        byteorder = Byteorder(byteorder)
    end
    if offset isa Nothing
        offset = 0
    end
    if strides isa Nothing
        # Calculate byte strides in C order
        sz = sizeof(Type(datatype))
        strides = reverse(cumprod([sz; reverse(shape[(begin + 1):end])]))
    end
    return NDArray(
        lazy_block_headers, source, data, Vector{Int64}(shape), datatype, byteorder, Int64(offset), Vector{Int64}(strides)
    )
end

function make_construct_yaml_ndarray(block_headers::LazyBlockHeaders)
    function construct_yaml_ndarray(constructor::YAML.Constructor, node::YAML.Node)
        mapping = YAML.construct_mapping(constructor, node)
        source = get(mapping, "source", nothing)::Union{Nothing,Integer}
        data = get(mapping, "data", nothing)::Union{Nothing,AbstractVector}
        shape = mapping["shape"]::AbstractVector{<:Integer}
        datatype = mapping["datatype"]::AbstractString
        byteorder = get(mapping, "byteorder", nothing)::Union{Nothing,AbstractString}
        offset = get(mapping, "offset", nothing)::Union{Nothing,Integer}
        strides = get(mapping, "strides", nothing)::Union{Nothing,AbstractVector{<:Integer}}
        return NDArray(block_headers, source, data, shape, datatype, byteorder, offset, strides)
    end
    return construct_yaml_ndarray
end

function Base.getindex(ndarray::NDArray)
    if ndarray.data !== nothing
        data = ndarray.data
        if ndarray.byteorder != host_byteorder
            error(
                "ndarray byteorder does not match system byteorder; ",
                "byteorder swapping not yet implemented."
            )
        end
    elseif ndarray.source !== nothing
        data = read_block(ndarray.lazy_block_headers.block_headers[ndarray.source + 1])
        # Handle strides and offset.
        # Do this before imposing the datatype because strides are given in bytes.
        typesize = sizeof(Type(ndarray.datatype))
        # Add a new dimension for the bytes that make up the datatype
        shape = (typesize, reverse(ndarray.shape)...)
        strides = (1, reverse(ndarray.strides)...)
        data = StridedView(data, Int.(shape), Int.(strides), Int(ndarray.offset))
        # Impose datatype
        data = reinterpret(Type(ndarray.datatype), data)
        # Remove the new dimension again
        data = reshape(data, shape[2:end])
        # Correct byteorder if necessary.
        # Do this after imposing the datatype since byteorder depends on the datatype.
        if ndarray.byteorder != host_byteorder
            map!(bswap, data, data)
        end
    else
        # Caught in the constructor for `NDArray`. This branch would imply that
        # `ndarray` is in invalid state; neither `source` nor `data` is given.
        @assert false
    end

    # Check array layout
    @assert size(data) == Tuple(reverse(ndarray.shape)) # `data` conforms to specified `ndarray.shape`
    @assert eltype(data) == Type(ndarray.datatype) # `data` matches type specified by `ndarray.datatype`
    if sizeof(eltype(data)) .* Base.strides(data) != Tuple(reverse(ndarray.strides))
        error("`data` has different stride from `ndarray.strides`")
    end

    return data::AbstractArray
end

################################################################################

struct NDArrayChunk
    start::Vector{Int64}
    ndarray::NDArray

    function NDArrayChunk(start::Vector{Int64}, ndarray::NDArray)
        if length(start) != length(ndarray.strides)
            error("`start` and `strides` have a different number of elements")
        end
        if any(start .< 0)
            error("`start` cannot contain negative values")
        end
        return new(start, ndarray)
    end
end

function NDArrayChunk(start::AbstractVector{<:Integer}, ndarray::NDArray)
    return NDArrayChunk(Vector{Int64}(start), ndarray)
end

function make_construct_yaml_ndarray_chunk(block_headers::LazyBlockHeaders)
    function construct_yaml_ndarray_chunk(constructor::YAML.Constructor, node::YAML.Node)
        mapping = YAML.construct_mapping(constructor, node)
        start = mapping["start"]::AbstractVector{<:Integer}
        ndarray = mapping["ndarray"]::NDArray
        return NDArrayChunk(start, ndarray)
    end
    return construct_yaml_ndarray_chunk
end

struct ChunkedNDArray
    shape::Vector{Int64}
    datatype::Datatype
    chunks::AbstractVector{NDArrayChunk}

    function ChunkedNDArray(shape::Vector{Int64}, datatype::Datatype, chunks::Vector{NDArrayChunk})
        if any(shape .< 0)
            error("`shape` cannot contain negative values")
        end
        for chunk in chunks
            if length(chunk.start) != length(shape)
                error("Different number of dimensions specified by `chunks` and `shape`")
            end
            # We allow overlaps and gaps in the chunks
            if !all(chunk.start .<= shape)
                error("`chunk.start` exceeds number of elements in dimension")
            end
            if !all(chunk.start + chunk.ndarray.shape .<= shape)
                error("`chunk` exceeds number of elements as specified by `shape`")
            end
            if chunk.ndarray.datatype != datatype
                error("`datatype` and type of `chunk` cannot be different")
            end
        end
        return new(shape, datatype, chunks)
    end
end

function ChunkedNDArray(
    shape::AbstractVector{<:Integer}, datatype::Union{Datatype,AbstractString}, chunks::AbstractVector{NDArrayChunk}
)
    if datatype isa AbstractString
        datatype = Datatype(datatype)
    end
    return ChunkedNDArray(Vector{Int64}(shape), datatype, chunks)
end

function make_construct_yaml_chunked_ndarray(block_headers::LazyBlockHeaders)
    function construct_yaml_chunked_ndarray(constructor::YAML.Constructor, node::YAML.Node)
        mapping = YAML.construct_mapping(constructor, node)
        shape = mapping["shape"]::AbstractVector{<:Integer}
        datatype = mapping["datatype"]::AbstractString
        chunks = mapping["chunks"]::AbstractVector{NDArrayChunk}
        return ChunkedNDArray(shape, datatype, chunks)
    end
    return construct_yaml_chunked_ndarray
end

function Base.getindex(chunked_ndarray::ChunkedNDArray)
    shape = chunked_ndarray.shape
    datatype = Type(chunked_ndarray.datatype)
    data = Array{datatype}(undef, reverse(shape)...)
    for chunk in chunked_ndarray.chunks
        start = CartesianIndex(reverse(chunk.start .+ 1)...)
        shape = CartesianIndex(reverse(chunk.start + chunk.ndarray.shape)...)
        data[start:shape] .= chunk.ndarray[]
    end
    return data::AbstractArray
end

################################################################################

struct ASDFFile
    filename::AbstractString
    metadata::OrderedDict{Any,Any}
    lazy_block_headers::LazyBlockHeaders
end

function YAML.write(file::ASDFFile)
    return "[ASDF file \"$(file.filename)\"]\n" * YAML.write(file.metadata)
end

Base.getindex(af::ASDFFile, key) = af.metadata[key]

struct ASDFTreeNode
    key::Any
    value::Any
end

AbstractTrees.children(n::ASDFTreeNode) =
    n.value isa ASDFFile         ? [ASDFTreeNode(k, v) for (k, v) in n.value.metadata] :
    n.value isa AbstractDict     ? [ASDFTreeNode(k, v) for (k, v) in sort(collect(n.value); by = first)] : ()

AbstractTrees.printnode(io::IO, n::ASDFTreeNode) =
    n.key === nothing            ? print(io, basename(n.value.filename))                                         :
    n.value isa AbstractDict     ? print(io, n.key, "::",  typeof(n.key))                              :
    n.value isa NDArray          ? print(io, n.key, "::",  typeof(n.value), " | shape = ", n.value.shape) :
    n.value isa AbstractVector   ? print(io, n.key, "::" , typeof(n.value), " | shape = ", size(n.value)) :
                                   print(io, n.key, "::",  typeof(n.value), " | ", n.value)

"""
    info(io::IO, af::ASDFFile; max_rows = 20)

Display up to `max_rows` lines of `af` tree. `Base.show` calls this function internally to display this type. Set `max_rows = Inf` to display all rows.

## Examples

```jldoctest
julia> using OrderedCollections: OrderedDict

julia> doc = OrderedDict("field_\$(i)" => rand(10) for i in 1:25);

julia> save("long.asdf", doc)

julia> af = load("long.asdf")
long.asdf
├─ field_1::Vector{Float64} | shape = (10,)
├─ field_2::Vector{Float64} | shape = (10,)
├─ field_3::Vector{Float64} | shape = (10,)
├─ field_4::Vector{Float64} | shape = (10,)
├─ field_5::Vector{Float64} | shape = (10,)
├─ field_6::Vector{Float64} | shape = (10,)
├─ field_7::Vector{Float64} | shape = (10,)
├─ field_8::Vector{Float64} | shape = (10,)
├─ field_9::Vector{Float64} | shape = (10,)
├─ field_10::Vector{Float64} | shape = (10,)
├─ field_11::Vector{Float64} | shape = (10,)
├─ field_12::Vector{Float64} | shape = (10,)
├─ field_13::Vector{Float64} | shape = (10,)
├─ field_14::Vector{Float64} | shape = (10,)
├─ field_15::Vector{Float64} | shape = (10,)
├─ field_16::Vector{Float64} | shape = (10,)
├─ field_17::Vector{Float64} | shape = (10,)
├─ field_18::Vector{Float64} | shape = (10,)
├─ field_19::Vector{Float64} | shape = (10,)
  ⋮  (7) more rows

julia> ASDF.info(af; max_rows = 5)
long.asdf
├─ field_1::Vector{Float64} | shape = (10,)
├─ field_2::Vector{Float64} | shape = (10,)
├─ field_3::Vector{Float64} | shape = (10,)
├─ field_4::Vector{Float64} | shape = (10,)
  ⋮  (22) more rows

julia> ASDF.info(af; max_rows = Inf)
long.asdf
├─ field_1::Vector{Float64} | shape = (10,)
├─ field_2::Vector{Float64} | shape = (10,)
├─ field_3::Vector{Float64} | shape = (10,)
├─ field_4::Vector{Float64} | shape = (10,)
├─ field_5::Vector{Float64} | shape = (10,)
├─ field_6::Vector{Float64} | shape = (10,)
├─ field_7::Vector{Float64} | shape = (10,)
├─ field_8::Vector{Float64} | shape = (10,)
├─ field_9::Vector{Float64} | shape = (10,)
├─ field_10::Vector{Float64} | shape = (10,)
├─ field_11::Vector{Float64} | shape = (10,)
├─ field_12::Vector{Float64} | shape = (10,)
├─ field_13::Vector{Float64} | shape = (10,)
├─ field_14::Vector{Float64} | shape = (10,)
├─ field_15::Vector{Float64} | shape = (10,)
├─ field_16::Vector{Float64} | shape = (10,)
├─ field_17::Vector{Float64} | shape = (10,)
├─ field_18::Vector{Float64} | shape = (10,)
├─ field_19::Vector{Float64} | shape = (10,)
├─ field_20::Vector{Float64} | shape = (10,)
├─ field_21::Vector{Float64} | shape = (10,)
├─ field_22::Vector{Float64} | shape = (10,)
├─ field_23::Vector{Float64} | shape = (10,)
├─ field_24::Vector{Float64} | shape = (10,)
├─ field_25::Vector{Float64} | shape = (10,)
└─ asdf/library::String
   ├─ author::String | Erik Schnetter <schnetter@gmail.com>
   ├─ homepage::String | https://github.com/JuliaAstro/ASDF.jl
   ├─ name::String | ASDF.jl
   └─ version::String | 2.0.0
"""
function info(io::IO, af::ASDFFile; max_rows = 20)
    root = ASDFTreeNode(nothing, af)
    n_rows = sum(1 for _ in AbstractTrees.PostOrderDFS(root))

    if n_rows ≤ max_rows
        AbstractTrees.print_tree(io, root)
    else
        # Store entire tree in `buf`
        buf = IOBuffer()
        AbstractTrees.print_tree(buf, root)
        # Only print up to `n_rows` lines from that buffer
        lines = split(String(take!(buf)), '\n', keepempty = false)
        foreach(l -> println(io, l), Iterators.take(lines, max_rows))
        println(io, "  ⋮  (", n_rows - max_rows, ") more rows")
    end
end
info(af; kwargs...) = info(stdout, af; kwargs...)

Base.show(io::IO, ::MIME"text/plain", af::ASDFFile) = info(io, af) # Display up to `max_rows` by default

################################################################################

ordered_map_constructor = (constructor, node) -> YAML.construct_mapping(OrderedDict{Any,Any}, constructor, node)
asdf_constructors = copy(YAML.default_yaml_constructors)
delete!(asdf_constructors, "tag:yaml.org,2002:map")  # Let dicttype= handle plain maps
asdf_constructors["tag:stsci.edu:asdf/core/asdf-1.1.0"] = ordered_map_constructor
asdf_constructors["tag:stsci.edu:asdf/core/software-1.0.0"] = ordered_map_constructor
asdf_constructors["tag:stsci.edu:asdf/core/extension_metadata-1.0.0"] = ordered_map_constructor

function load_file(filename::AbstractString; extensions = false, validate_checksum = true)
    if extensions
        # Use fallbacks for now
        asdf_constructors[nothing] = (constructor, node) -> begin
            if node isa YAML.MappingNode
                return YAML.construct_mapping(constructor, node)
            elseif node isa YAML.SequenceNode
                return YAML.construct_sequence(constructor, node)
            else
                return YAML.construct_scalar(constructor, node)
            end
        end
    end

    io = open(filename, "r")
    lazy_block_headers = LazyBlockHeaders()
    construct_yaml_ndarray = make_construct_yaml_ndarray(lazy_block_headers)
    construct_yaml_chunked_ndarray = make_construct_yaml_chunked_ndarray(lazy_block_headers)
    construct_yaml_ndarray_chunk = make_construct_yaml_ndarray_chunk(lazy_block_headers)

    asdf_constructors′ = copy(asdf_constructors)
    asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-1.0.0"] = construct_yaml_ndarray
    asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-1.1.0"] = construct_yaml_ndarray
    asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-chunk-1.0.0"] = construct_yaml_ndarray_chunk
    asdf_constructors′["tag:stsci.edu:asdf/core/chunked-ndarray-1.0.0"] = construct_yaml_chunked_ndarray

    metadata = YAML.load(io, asdf_constructors′; dicttype = OrderedDict{Any, Any})
    # lazy_block_headers.block_headers = find_all_blocks(io, position(io))
    lazy_block_headers.block_headers = find_all_blocks(io; validate_checksum)
    return ASDFFile(filename, metadata, lazy_block_headers)
end

"""
    load(f::AbstractString)

Load an asdf file at filepath `f`.

## Examples

```jldoctest
julia> using OrderedCollections: OrderedDict

julia> doc = OrderedDict("field_\$(i)" => rand(10) for i in 1:5); # Create some sample data

julia> save("myfile.asdf", doc)

julia> load("myfile.asdf")
myfile.asdf
├─ field_1::Vector{Float64} | shape = (10,)
├─ field_2::Vector{Float64} | shape = (10,)
├─ field_3::Vector{Float64} | shape = (10,)
├─ field_4::Vector{Float64} | shape = (10,)
├─ field_5::Vector{Float64} | shape = (10,)
└─ asdf/library::String
   ├─ author::String | Erik Schnetter <schnetter@gmail.com>
   ├─ homepage::String | https://github.com/JuliaAstro/ASDF.jl
   ├─ name::String | ASDF.jl
   └─ version::String | 2.0.0
```
"""
function fileio_load(f::File{format"ASDF"})
    return load_file(f.filename)
end

@doc (@doc fileio_load) load

################################################################################
################################################################################
################################################################################

struct ASDFLibrary
    name::AbstractString
    author::AbstractString
    homepage::AbstractString
    version::AbstractString
end
function YAML._print(io::IO, val::ASDFLibrary, level::Int=0, ignore_level::Bool=false)
    println(io, "!core/software-1.0.0")
    library = OrderedDict(:name => val.name, :author => val.author, :homepage => val.homepage, :version => val.version)
    YAML._print(io, library, level, ignore_level)
end

struct NDArrayWrapper
    array::AbstractArray
    compression::Compression
    inline::Bool
    lz4_layout::Symbol
end
function NDArrayWrapper(array::AbstractArray; compression::Compression=C_Bzip2, inline::Bool=false, lz4_layout::Symbol=:block)
    return NDArrayWrapper(array, compression, inline, lz4_layout)
end
Base.getindex(val::NDArrayWrapper) = val.array

struct Blocks
    arrays::Vector{NDArrayWrapper}
    positions::Vector{Int64}
    Blocks() = new(NDArrayWrapper[], Int64[])
end
function Base.empty!(blocks::Blocks)
    empty!(blocks.arrays)
    empty!(blocks.positions)
    nothing
end
Base.isempty(blocks::Blocks) = isempty(blocks.arrays) && isempty(blocks.positions)
# Unfortunately we need a global variable.
# This means that `write_file` is not thread-safe.
const blocks::Blocks = Blocks()

function YAML._print(io::IO, val::NDArrayWrapper, level::Int=0, ignore_level::Bool=false)
    if val.inline
        data = val.array
        # Split multidimensional arrays into array-of-arrays
        data = eachslice(data; dims=Tuple(2:ndims(data)))
        ndarray = OrderedDict(
            :data => data,
            :shape => collect(reverse(size(val.array)))::Vector{<:Integer},
            :datatype => string(Datatype(eltype(val.array))),
            # :offset => 0::Integer,
            # :strides => ::Vector{Int64},
        )
    else
        global blocks
        source = length(blocks.arrays)
        # `write_file()` has a corresponding `push!()` to `blocks.positions`
        push!(blocks.arrays, val)
        ndarray = OrderedDict(
            :source => source::Integer,
            :shape => collect(reverse(size(val.array)))::Vector{<:Integer},
            :datatype => string(Datatype(eltype(val.array))),
            :byteorder => string(host_byteorder::Byteorder),
            # :offset => 0::Integer,
            # :strides => ::Vector{Int64},
        )
    end
    # println(io, YAML._indent("-\n", level), "!core/chunked-ndarray-1.0.0")
    println(io, "!core/ndarray-1.0.0")
    YAML._print(io, ndarray, level, ignore_level)
end

function encode_Lz4_block(input::AbstractVector{UInt8}; chunk_size::Int = 1024 * 1024 * 8)
    out = UInt8[]
    offset = 1
    while offset <= length(input)
        chunk_end = min(offset + chunk_size - 1, length(input))
        chunk = @view input[offset:chunk_end]

        # Compress the raw chunk with LZ4 block codec
        # LZ4BlockEncodeOptions does NOT prepend the uncompressed size,
        # so we must prepend the LE uint32 ourselves to match Python's
        # lz4.block.compress(store_size=True) behaviour.
        compressed_payload = encode(LZ4BlockEncodeOptions(), chunk)
        uncompressed_size = UInt32(length(chunk))
        compressed_chunk_size = UInt32(4 + length(compressed_payload))  # LE prefix + raw payload

        # Outer ASDF envelope: big-endian compressed chunk size (includes the 4-byte LE prefix)
        append!(out, native2big_U32(compressed_chunk_size))

        # Inner lz4.block store_size=True prefix: little-endian uncompressed size
        append!(out, [
            (uncompressed_size >>> 0x00) & 0xff,
            (uncompressed_size >>> 0x08) & 0xff,
            (uncompressed_size >>> 0x10) & 0xff,
            (uncompressed_size >>> 0x18) & 0xff,
        ])

        # Raw LZ4 block payload
        append!(out, compressed_payload)
        offset = chunk_end + 1
    end

    return out
end

function write_file(filename::AbstractString, document::AbstractDict)
    # Set up block descriptors
    global blocks
    empty!(blocks)

    # Ensure standard tags are present
    # TODO:
    # - [ ] provide a function that generates a standard empty document
    # - [x] don't modify the input
    # - [x] remove the `{Any,Any}` in the test cases
    # - [ ] maybe make the document not a `Dict` but the stuff with the `metadata` that the writer returns?
    # - [ ] preserve insertion order? https://github.com/JuliaAstro/ASDF.jl/tree/ordered
    library = ASDFLibrary(software_name, software_author, software_homepage, software_version)
    full_document = merge(document, OrderedDict{Any, Any}("asdf/library" => library))

    # Write YAML part of file
    io = open(filename, "w")
    println(
        io,
        """#ASDF 1.0.0
           #ASDF_STANDARD 1.2.0
           # This is an ASDF file <https://asdf-standard.readthedocs.io/>
           %YAML 1.1
           %TAG ! tag:stsci.edu:asdf/
           ---
           !core/asdf-1.1.0""",
    )
    YAML.write(io, full_document)
    println(io, "...")

    # Write blocks
    for array in blocks.arrays
        source = length(blocks.positions)
        pos = position(io)
        push!(blocks.positions, pos)

        # TODO: create function write_block_header
        max_header_size = 6 + 48
        header = Array{UInt8}(undef, max_header_size)
        # # Skip the header.; the real header will be
        # # written later once its contents are known
        # skip(io, length(header))

        token = block_magic_token
        header_size = 48
        flags = 0               # not streamed
        compression = compression_keys[array.compression]
        data_size = sizeof(array.array)

        # Write block
        # TODO: create function write_block

        input = array.array
        # Make dense (contiguous) if necessary
        input = input isa DenseArray ? input : Array(input)
        # Reshape to 1D
        input = reshape(input, :)
        # Reinterpret as UInt8
        input = reinterpret(UInt8, input)

        # TODO: Write directly to file
        if array.compression == C_None
            data = input
        elseif array.compression == C_Xz
            # Copy
            # TODO: Don't copy input
            input = input isa Vector ? input : Vector(input)
            data = transcode(XzCompressor, input)
        elseif array.compression == C_Lz4 && array.lz4_layout == :block
            data = encode_Lz4_block(input)
            #data = encode(LZ4BlockEncodeOptions(), input) # Not compatible with Python asdf
        else
            if array.compression == C_Blosc
                encode_options = BloscEncodeOptions(; clevel=9, doshuffle=2, typesize=sizeof(eltype(array.array)), compressor="zstd")
            elseif array.compression == C_Bzip2
                encode_options = BZ2EncodeOptions(; blockSize100k=9)
            elseif array.compression == C_Lz4 && array.lz4_layout == :frame
                encode_options = LZ4FrameEncodeOptions(; compressionLevel=12, blockSizeID=7)
            elseif array.compression == C_Zlib
                encode_options = ZlibEncodeOptions(; level=9)
            elseif array.compression == C_Zstd
                encode_options = ZstdEncodeOptions(; compressionLevel=22)
            else
                error("`array` has invalid state: `compression` field has value not specified in `Compression` enum.")
            end
            data = encode(encode_options, input)
        end

        # Don't compress unless it reduces the size
        if length(data) >= length(input)
            compression = compression_keys[C_None]
            data = input
        end

        # We need the standard, dense layout
        data::AbstractVector{UInt8}
        data::Union{DenseArray,Base.ReinterpretArray{<:Any,<:Any,<:Any,<:DenseArray}}

        used_size = length(data)
        allocated_size = used_size
        checksum = Vector{UInt8}(md5(data))

        # Fill header
        header[1:4] .= token
        header[5:6] .= native2big_U16(header_size)
        header[7:10] .= native2big_U32(flags)
        header[11:14] .= compression
        header[15:22] .= native2big_U64(allocated_size)
        header[23:30] .= native2big_U64(used_size)
        header[31:38] .= native2big_U64(data_size)
        header[39:54] .= checksum

        # Write header
        # endpos = position(io)
        # seek(io, pos)
        write(io, header)
        # seek(io, endpos)

        # Write data
        write(io, data)

        # Check consistency
        endpos = position(io)
        @assert endpos == pos + 6 + header_size + allocated_size # Ending position matches number of bytes written
    end
    # Global `blocks` should have valid state: number of arrays matches number of `positions`.
    # If not, check that `write_file()` and `YAML._print()` match.
    @assert length(blocks.positions) == length(blocks.arrays)

    # Write block list
    println(io, "#ASDF BLOCK INDEX")
    println(io, "%YAML 1.1")
    println(io, "---")
    print(io, "[")
    for pos in blocks.positions
        print(io, pos, ",")
    end
    println(io, "]")
    println(io, "...")

    # Close file
    close(io)

    # Clean up
    empty!(blocks)

    # Done.
    return nothing
end

"""
    save(f::String, data)

Save `data` to an asdf file at filepath `f`.

## Examples

```jldoctest
julia> using OrderedCollections: OrderedDict

julia> data = OrderedDict("field_\$(i)" => rand(10) for i in 1:5); # Create some sample data

julia> save("myfile.asdf", data)
```
"""
function fileio_save(f::File{format"ASDF"}, data)
    return write_file(f.filename, data)
end

@doc (@doc fileio_save) save

end
