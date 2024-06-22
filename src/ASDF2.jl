module ASDF2

using BlockArrays
using Blosc
# using Blosc2
using CodecBzip2
using CodecLz4
using CodecZlib
using MD5
using StridedViews
using YAML

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
end

mutable struct LazyBlockHeaders
    block_headers::Vector{BlockHeader}
    LazyBlockHeaders() = new(BlockHeader[])
end

const block_magic_token = UInt8[0xd3, 0x42, 0x4c, 0x4b] # "\323BLK"

find_first_block(io::IO) = find_next_block(io, Int64(0))
function find_next_block(io::IO, pos::Int64)
    sz = 1000 * 1000
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

function read_block_header(io::IO, position::Int64)
    # Read block header
    max_header_size = 6 + 48
    header = Array{UInt8}(undef, max_header_size)
    seek(io, position)
    nb = readbytes!(io, header)
    # TODO: Better error message
    @assert nb == length(header)

    # Decode block header
    token = @view header[1:4]
    header_size = big2native_U16(@view header[5:6])
    flags = big2native_U32(@view header[7:10])
    compression = @view header[11:14]
    allocated_size = big2native_U64(@view header[15:22])
    used_size = big2native_U64(@view header[23:30])
    data_size = big2native_U64(@view header[31:38])
    checksum = @view header[39:54]

    # TODO: Better error message
    @assert token == block_magic_token

    STREAMED = Bool(flags & 0x1)
    # We don't handle streamed blocks yet
    @assert !STREAMED

    # TODO: Better error message
    @assert allocated_size >= used_size

    return BlockHeader(io, position, token, header_size, flags, compression, allocated_size, used_size, data_size, checksum)
end

function find_all_blocks(io::IO, pos::Int64=Int64(0))
    headers = BlockHeader[]
    pos = find_next_block(io, pos)
    while pos !== nothing
        header = read_block_header(io, pos)
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
    # TODO: Better error message
    @assert nb == length(data)

    # Check checksum
    if any(header.checksum != 0)
        actual_checksum = md5(data)
        # TODO: Better error message
        @assert all(actual_checksum == header.checksum)
    end

    # Decompress data
    if all(header.compression .== 0)
        # do nothing, the block is uncompressed
    elseif header.compression == Vector{UInt8}("blsc")
        data = Blosc.decompress(UInt8, data)::AbstractVector{UInt8}
    elseif header.compression == Vector{UInt8}("bls2")
        @assert false
        #     data = Blosc.decompress(UInt8, data)::AbstractVector{UInt8}
    elseif header.compression == Vector{UInt8}("bzp2")
        # TODO: Read directly from file
        data = transcode(Bzip2Decompressor, data)::AbstractVector{UInt8}
    elseif header.compression == Vector{UInt8}("lz4\0")
        # TODO: Read directly from file
        data = transcode(Lz4Decompressor, data)::AbstractVector{UInt8}
    elseif header.compression == Vector{UInt8}("zlib")
        # TODO: Read directly from file
        data = transcode(ZlibDecompressor, data)::AbstractVector{UInt8}
    else
        # TODO: Better error message
        @assert false
    end

    # TODO: Better error message
    @assert length(data) == header.data_size

    return data
end

################################################################################

"""
    @enum ASDF2.Byteorder Byteorder_little Byteorder_big
"""
@enum Byteorder Byteorder_little Byteorder_big
const byteorder_string_dict = Dict{Byteorder,String}(Byteorder_little => "little", Byteorder_big => "big")
const string_byteorder_dict = Dict{String,Byteorder}(val => key for (key, val) in byteorder_string_dict)

"""
    ASDF2.Byteorder(str::AbstractString)::Byteorder
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
    strides::Vector{Int64}
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
        @assert (source === nothing) + (data === nothing) == 1
        @assert source === nothing || source >= 0
        @assert data === nothing || eltype(data) == Type(datatype)
        @assert data === nothing || size(data) == Tuple(reverse(shape))
        @assert offset >= 0
        @assert length(shape) == length(strides)
        @assert all(shape .>= 0)
        @assert all(strides .> 0)
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
        while eltype(data) <: AbstractVector
            data = reduce(vcat, data)
        end
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
        strides = Int64[1 for sh in shape]
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
        @assert ndarray.byteorder == host_byteorder
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
        @assert false
    end

    # Check array layout
    @assert size(data) == Tuple(reverse(ndarray.shape))
    @assert eltype(data) == Type(ndarray.datatype)
    # TODO: Check strides (but how?)

    return data::AbstractArray
end

################################################################################

struct NDArrayChunk
    start::Vector{Int64}
    ndarray::NDArray

    function NDArrayChunk(start::Vector{Int64}, ndarray::NDArray)
        @assert length(start) == length(ndarray.strides)
        @assert all(start .>= 0)
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
        @assert all(shape .>= 0)
        for chunk in chunks
            @assert length(chunk.start) == length(shape)
            # We allow overlaps and gaps in the chunks
            @assert all(chunk.start .<= shape)
            @assert all(chunk.start + chunk.ndarray.shape .<= shape)
            @assert chunk.ndarray.datatype == datatype
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
    metadata::Dict{Any,Any}
    lazy_block_headers::LazyBlockHeaders
end

function YAML.write(file::ASDFFile)
    return "[ASDF file \"$(file.filename)\"]\n" * YAML.write(file.metadata)
end

################################################################################

asdf_constructors = copy(YAML.default_yaml_constructors)
asdf_constructors["tag:stsci.edu:asdf/core/asdf-1.1.0"] = asdf_constructors["tag:yaml.org,2002:map"]
asdf_constructors["tag:stsci.edu:asdf/core/software-1.0.0"] = asdf_constructors["tag:yaml.org,2002:map"]

function load_file(filename::AbstractString)
    io = open(filename, "r")
    lazy_block_headers = LazyBlockHeaders()
    construct_yaml_ndarray = make_construct_yaml_ndarray(lazy_block_headers)
    construct_yaml_chunked_ndarray = make_construct_yaml_chunked_ndarray(lazy_block_headers)
    construct_yaml_ndarray_chunk = make_construct_yaml_ndarray_chunk(lazy_block_headers)

    asdf_constructors′ = copy(asdf_constructors)
    asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-1.0.0"] = construct_yaml_ndarray
    asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-chunk-1.0.0"] = construct_yaml_ndarray_chunk
    asdf_constructors′["tag:stsci.edu:asdf/core/chunked-ndarray-1.0.0"] = construct_yaml_chunked_ndarray

    metadata = YAML.load(io, asdf_constructors′)
    # lazy_block_headers.block_headers = find_all_blocks(io, position(io))
    lazy_block_headers.block_headers = find_all_blocks(io)
    return ASDFFile(filename, metadata, lazy_block_headers)
end

end
