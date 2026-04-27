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

"""
Identifies the compression algorithm used for a data block. Available variants:

| Scheme           | 4-byte key     | Backend                | Description                                                   |
| :--------------- | :------------- | :--------------------- | :------------------------------------------------------------ |
| `C_None`         | `\\0\\0\\0\\0` | --                     |  Fast I/O speed, no CPU overhead                              |
| `C_Blosc`        | `blsc`         | ChunkCodecLibBlosc.jl  | Multi-threaded, shuffle-aware, best with typed numeric arrays |
| `C_Blosc2`       | `bls2`         | See [Issue #49](https://github.com/JuliaIO/ChunkCodecs.jl/issues/49) | Like Blosc but supports more than 2 GB of data                |
| `C_Bzip2`        | `bzp2`         | ChunkCodecLibBzip2.jl  | Good ratio, moderate speed (default)                          |
| `C_Lz4` (:block) | `lz4\\0`       | ChunkCodecLibLz4.jl    | Fastest decompression, Python-compatible                      |
| `C_Lz4` (:frame) | `lz4\\0`       | ChunkCodecLibLz4.jl    | LZ4 frame format for non-Python consumers                     |
| `C_Xz`           | `xz\\0\\0`     | CodecXz.jl             | Highest compression ratio, slowest                            |
| `C_Zlib`         | `zlib`         | ChunkCodecLibZlib.jl   | Broad compatibility                                           |
| `C_Zstd`         | `zstd`         | ChunkCodecLibZstd.jl   | Best ratio/speed trade-off                                    |
"""
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
"""
    BlockHeader

Parsed representation of a single ASDF binary block header.

Every binary block in an ASDF file begins with a fixed-layout header that describes the block's compression, size, and integrity checksum. `BlockHeader` captures all decoded fields from that header, together with the `IO` handle and file position needed to subsequently read the block's data payload.

# Fields

| Field               | Description |
| :------------------ | :---------- |
| `io`                | The open file handle from which the block's data can be read. |
| `position`          | Absolute byte offset of the block magic token within `io`. |
| `token`             | 4-byte magic token. Always equal to [`block_magic_token`](@ref) (`\\323BLK`). |
| `header_size`       | Size of the extended header region in bytes (excludes the 6-byte prefix). |
| `flags`             | Block flags. Bit 0 (`0x1`) indicates a streamed block (not currently supported). |
| `compression`       | 4-byte compression key (e.g. `"zstd"`, `"bzp2"`). |
| `allocated_size`    | Number of bytes allocated in the file for this block's data (≥ `used_size`). |
| `used_size`         | Number of bytes of (compressed) data actually written. |
| `data_size`         | Number of bytes of the *uncompressed* data. |
| `checksum`          | 16-byte MD5 digest of the compressed data, or all zeros if omitted. |
| `validate_checksum` | When `true`, [`ASDF.read_block`](@ref) verifies the MD5 digest before returning data. |

# File layout

The block occupies the following byte range within `io`, starting at `position`:

|                                |                      | |
| :--                            | :--                  | :-- |
| `[position]`                   | 4 bytes              | magic token |
| `[position + 4]`               | 2 bytes              | header_size  (big-endian UInt16) |
| `[position + 6]`               | header_size bytes    |      extended header fields |
| `[position + 6 + header_size]` | allocated_size bytes |  data payload |

The extended header (always 48 bytes in the current implementation) contains, in order: `flags` (4 B), `compression` (4 B), `allocated_size` (8 B), `used_size` (8 B), `data_size` (8 B), and `checksum` (16 B).

All multi-byte integers in the header are stored in **big-endian** byte order.
"""
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

"""
    LazyBlockHeaders

A mutable container holding the complete list of [`ASDF.BlockHeader`](@ref) values scanned from an ASDF file, shared by reference with every [`ASDF.NDArray`](@ref)
and [`ASDF.ChunkedNDArray`](@ref) constructed during parsing.

# Reference sharing

Every [`ASDF.NDArray`](@ref) created during parsing of a given file holds a reference to the same `LazyBlockHeaders` instance. When `ndarray[]` is called, it indexes into `lazy_block_headers.block_headers` using the array's zero-based `source` field:

```julia
header = ndarray.lazy_block_headers.block_headers[ndarray.source + 1]
data   = ASDF.read_block(header)
```

Because `block_headers` is populated after all `NDArray` objects are constructed, no array needs to be updated individually when block scanning completes. The shared mutable reference propagates the result automatically.

# Mutability

`LazyBlockHeaders` is a `mutable struct` solely to allow `block_headers` to be assigned after construction. The field is written exactly once per file load, immediately after `YAML.load` within [`ASDF.load_file`](@ref) returns. It is never modified again during normal use. Treat it as effectively immutable after [`load_file`](@ref) returns.
"""
mutable struct LazyBlockHeaders
    block_headers::Vector{BlockHeader}
    LazyBlockHeaders() = new(BlockHeader[])
end

"""
    block_magic_token

The 4-byte sentinel `UInt8[0xd3, 0x42, 0x4c, 0x4b]`.
"""
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

"""
    read_block_header(io::IO, position::Int64; validate_checksum::Bool)

Constructs an [`ASDF.BlockHeader`](@ref) by parsing the file at a given offset.
"""
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

"""
    find_all_blocks(io::IO, pos::Int64=Int64(0); validate_checksum::Bool)

Scans an `IO` stream and returns all [`ASDF.BlockHeader`](@ref) values found.
"""
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

"""
    read_block(header::BlockHeader)

Uses an [`ASDF.BlockHeader`](@ref) to read, verify, and decompress the data payload.
"""
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
    ASDF.Byteorder

Represents the byte order of array data stored in a block. Available variants:

- `Byteorder_little` : Little-endian
- `Byteorder_big`: Big-endian
"""
@enum Byteorder Byteorder_little Byteorder_big
const byteorder_string_dict = Dict{Byteorder,String}(Byteorder_little => "little", Byteorder_big => "big")
const string_byteorder_dict = Dict{String,Byteorder}(val => key for (key, val) in byteorder_string_dict)

"""
    ASDF.Byteorder(str::AbstractString)::Byteorder

Convenience conversion for [`ASDF.Byteorder`](@ref). Inverse of [`Base.string(byteorder::Byteorder)`](@ref).

# Examples

```jldoctest
julia> ASDF.Byteorder("little")
Byteorder_little::Byteorder = 0
```
"""
Byteorder(str::AbstractString) = string_byteorder_dict[str]

"""
    string(byteorder::Byteorder)::AbstractString

Convenience conversion for [`ASDF.Byteorder`](@ref). Inverse of [`ASDF.Byteorder(str::AbstractString)`](@ref).

# Examples

```jldoctest
julia> string(ASDF.Byteorder_little)
"little"
```
"""
Base.string(byteorder::Byteorder) = byteorder_string_dict[byteorder]
Base.show(io::IO, byteorder::Byteorder) = show(io, string(byteorder))

"""
    host_byteorder

Native byte order of the running machine, detected at load time. Defined by [`ASDF.Byteorder`](@ref).
"""
const host_byteorder = reinterpret(UInt8, UInt16[1])[1] == 1 ? Byteorder_little : Byteorder_big

################################################################################

"""
Maps ASDF datatype strings to Julia types. Note this is unrelated to `Base.DataType`. Defined mappings:

| ASDF string             | Julia type              |
| :---------------------- | :---------------------- |
| `bool8`                 | `Bool`                  |
| `int8` ... `int128`     | `Int8` ... `Int128`     |
| `uint8` ... `uint128`   | `UInt8` ... `UInt128`   |
| `float16` ... `float64` | `Float16` ... `Float64` |
| `complex32`             |  `Complex{Float16}`     |
| `complex64`             |  `Complex{Float32}`     |
| `complex128`            |  `Complex{Float64}`     |
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

"""
    NDArray

A lazily-materialized N-dimensional array stored in an ASDF file, either as a binary block or inline within the ASDF file.

`NDArray` is the in-memory representation of an `!core/ndarray-1.0.0` YAML node. It holds the array's shape, type, and layout metadata, but defers reading and decompressing block data until the array is explicitly materialized by calling [`Base.getindex(ndarray::NDArray)`](@ref).

# Fields

| Field                 | Description |
| :-------------------- | :---------- |
| `lazy_block_headers`  | Reference to the file's block header list. Used to resolve `source` indices at materialization time. |
| `source`              | Zero-based index of the backing binary block, or `nothing` for inline arrays. |
| `data`                | In-memory array for inline data, or `nothing` for block-backed arrays. |
| `shape`               | Array dimensions in **Python/C (row-major) order** — outermost dimension first. The equivalent Julia shape is `reverse(shape)`. |
| `datatype`            | Element type, as an [`ASDF.Datatype`](@ref) enum value. Convert to a Julia type with `Type(datatype)`. |
| `byteorder`           | Byte order of the stored data (`Byteorder_little` or `Byteorder_big`). |
| `offset`              | Byte offset from the start of the block to the first array element. Non-negative. |
| `strides`             | Byte strides in **Python/C (row-major) order**. Must all be positive and `length(strides) == length(shape)`. |
"""
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

"""
    Base.getindex(ndarray::NDArray)

Returns the fully materialized array. See [`ASDF.NDArray`](@ref) for definitions. When block-backed (`source` !== `nothing`), this reads and decompresses the block, applies offset and strides via a [`StridedViews.StridedView`](https://github.com/QuantumKitHub/StridedViews.jl), reinterprets bytes to `Type(datatype)`, and byte-swaps if `byteorder != host_byteorder`. The returned array satisfies:

```julia
size(result) == Tuple(reverse(ndarray.shape))
eltype(result) == Type(ndarray.datatype)
sizeof(eltype) .* strides(result) == Tuple(reverse(ndarray.strides))
```
"""
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

"""
    NDArrayChunk

A positioned tile within an [`ASDF.ChunkedNDArray`](@ref), pairing an [`ASDF.NDArray`](@ref) with a zero-based origin that locates the tile in the parent array's coordinate space.

# Fields

| Field     | Description |
| :-------- | :---------- |
| `start`   | Zero-based origin of the tile in **Python/C (row-major) order**, outermost dimension first. All elements must be non-negative. `length(start)` must equal `length(ndarray.strides)`. |
| `ndarray` | The tile data, including its own shape, datatype, byte order, and backing block reference. |
"""
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

"""
    ChunkedNDArray

A logical N-dimensional array assembled from a collection of arbitrarily-positioned [`ASDF.NDArrayChunk`](@ref) tiles, each backed by its own binary block or inline data.

`ChunkedNDArray` is the in-memory representation of a `!core/chunked-ndarray-1.X.Y` YAML node. It defines the shape and element type of the full logical array, but defers all data access to the individual chunks. The full array is only allocated and populated when [`Base.getindex(ndarray::NDArray)`](@ref) is called.

# Fields

| Field      | Description |
| :--------- | :---------- |
| `shape`    | Dimensions of the full logical array in **Python/C (row-major) order**, outermost dimension first. All elements must be non-negative. The equivalent Julia shape is `reverse(shape)`. |
| `datatype` | Element type shared by all chunks. Convert to a Julia type with `Type(datatype)`. |
| `chunks`   | Ordered collection of tiles that together populate the logical array. Tiles are written in iteration order when materializing. Later tiles overwrite earlier ones in any overlapping region. |
"""
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

"""
    Base.getindex(chunked_ndarray::ChunkedNDArray)

Allocates a dense array of shape `reverse(shape)` and fills it by calling `chunk.ndarray[]` for each chunk, placing the result at the correct offset.
"""
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

"""
    ASDFFile

The in-memory representation of a loaded ASDF file, combining the parsed YAML metadata tree with the binary block infrastructure needed to lazily materialize any array data it references.

# Fields

| Field                 | Description |
| :-------------------- | :---------- |
| `filename`            | Path of the file on disk, as passed to [`ASDF.load_file`](@ref). Used for display and diagnostics only. The file is not kept open after loading. |
| `metadata`            | The fully parsed YAML tree. Keys are strings matching the top-level YAML keys. Values may be any Julia type produced by the YAML constructors, including [`ASDF.NDArray`](@ref), [`ASDF.ChunkedNDArray`](@ref), nested `Dict`s, `Vector`s, and scalars. |
| `lazy_block_headers`  | All binary block headers found in the file, scanned once at load time. Shared by reference with every [`ASDF.NDArray`](@ref) in `metadata`, allowing them to locate and read their backing blocks on demand. |
"""
struct ASDFFile
    filename::AbstractString
    metadata::OrderedDict{Any,Any}
    lazy_block_headers::LazyBlockHeaders
end

function YAML.write(file::ASDFFile)
    return "[ASDF file \"$(file.filename)\"]\n" * YAML.write(file.metadata)
end

Base.getindex(af::ASDFFile, key) = af.metadata[key]
Base.setindex!(af::ASDFFile, value, key) = (af.metadata[key] = value)

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

julia> doc = OrderedDict(string("field_", i) => rand(10) for i in 1:25);

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
  ⋮  (11) more rows

julia> ASDF.info(af; max_rows = 5)
long.asdf
├─ field_1::Vector{Float64} | shape = (10,)
├─ field_2::Vector{Float64} | shape = (10,)
├─ field_3::Vector{Float64} | shape = (10,)
├─ field_4::Vector{Float64} | shape = (10,)
  ⋮  (26) more rows

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
```
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

"""
    load_file(filename::AbstractString; extensions = false, validate_checksum = true)

Reads an ASDF file from disk.

| Parameter           | Description                                                                                                      |
| :------------------ | :--------------------------------------------------------------------------------------------------------------- |
| `filename`          | Path to the `.asdf` file                                                                                         |
| `extensions`        | When `true`, unknown YAML tags are parsed leniently (as maps, sequences, or scalars) instead of raising an error |
| `validate_checksum` | When `true`, each block's MD5 checksum is verified against the stored value                                      |

Block data is located lazily. Block headers are scanned after the YAML is parsed, and array data (`ndarray`) is read only when [`Base.getindex(ndarray::NDArray)`](@ref) is called, i.e., `ndarray[]`.

!!! note "File handle lifetime"
    The file handle opened by `load_file` is retained for the lifetime of the returned [`ASDF.ASDFFile`](@ref) so that block data can be read on demand. Do not move, truncate, or overwrite the source file while any [`ASDF.NDArray`](@ref) from it may still be accessed.
"""
function load_file(filename::AbstractString; extensions = false, validate_checksum = true)
    ordered_map_constructor = (constructor, node) -> YAML.construct_mapping(OrderedDict{Any,Any}, constructor, node)
    asdf_constructors = copy(YAML.default_yaml_constructors)
    delete!(asdf_constructors, "tag:yaml.org,2002:map")  # Let dicttype= handle plain maps
    asdf_constructors["tag:stsci.edu:asdf/core/asdf-1.1.0"] = ordered_map_constructor
    asdf_constructors["tag:stsci.edu:asdf/core/software-1.0.0"] = ordered_map_constructor
    asdf_constructors["tag:stsci.edu:asdf/core/extension_metadata-1.0.0"] = ordered_map_constructor

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

julia> doc = OrderedDict(string("field_", i) => rand(10) for i in 1:5); # Create some sample data

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
function fileio_load(f::File{format"ASDF"}; kwargs...)
    return load_file(f.filename; kwargs...)
end

@doc (@doc fileio_load) load

################################################################################
################################################################################
################################################################################

"""
    ASDFLibrary

Software provenance metadata, serialized as a `!core/software-1.0.0 YAML` tag. [`ASDF.write_file`] inserts an entry automatically under the key `"asdf/library"` if one is not already present, using the package's own name, author, homepage, and version.
"""
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

"""
    NDArrayWrapper

A write-side wrapper around a Julia array that carries compression and layout options. Used as the value type when building a document dict for [`ASDF.write_file`](@ref).

Parameter     | Default   | Description                                                               |
| :---------- | :-------- | :------------------------------------------------------------------------ |
`compression` | `C_Bzip2` | Applied compression scheme                                                |
`inline`      | `false`   | Embed data in YAML instead of a binary block                              |
`lz4_layout`  | `:block`  | `:block` for Python-compatible chunked LZ4, `:frame` for LZ4 frame format |

!!! note
    If the compressed output is larger than the raw input, the block is stored uncompressed regardless of the chosen compression.
"""
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

"""
    Blocks

Module-level accumulator that collects [`ASDF.NDArrayWrapper`](@ref) values and their corresponding file positions during a single call to [`ASDF.write_file`](@ref).

`Blocks` acts as a two-phase write buffer. In the first phase, as the YAML tree is serialized, each non-inline [`ASDF.NDArrayWrapper`](@ref) appends itself to `arrays` and reserves a sequential source index. In the second phase, [`ASDF.write_file`](@ref) iterates over `arrays`, compresses and writes each block to disk, and records the resulting file offsets in `positions`. The finalized `positions` vector is then written as the ASDF block index at the end of the file.

!!! warning "Not thread-safe"
    A single instance of `Blocks` is held in the module-level constant `ASDF.blocks`. Because this global state is mutated by [`ASDF.write_file`](@ref), concurrent calls to `write_file` from multiple threads will corrupt each other's block lists. Do not call `write_file` concurrently.

# Fields

| Field        | Description |
| :----------  | :---------- |
| `arrays`     | Ordered list of arrays to be written as binary blocks, accumulated during YAML serialisation. The position of each wrapper in this vector is its zero-based block source index. |
| `positions`  | Absolute byte offsets of each written block within the output file, populated during the block-writing phase of [`ASDF.write_file`](@ref). `positions[i]` corresponds to `arrays[i]`. |

"""
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

"""
    write_file(filename::AbstractString, document::AbstractDict)

Writes an ASDF file to disk. `document` is a plain `Dict` whose values may include [`NDArrayWrapper`](@ref) instances. These are serialized as binary blocks with appropriate compression.

Layout of the output file:

1. ASDF/YAML header (`#ASDF 1.0.0, #ASDF_STANDARD 1.2.0, %YAML 1.1`)
1. YAML tree (`!core/asdf-1.1.0`)
1. Binary blocks — one per [`NDArrayWrapper`](@ref) that has `inline == false`
1. Block index (`#ASDF BLOCK INDEX`)
"""
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

julia> data = OrderedDict(string("field_", i) => rand(10) for i in 1:5); # Create some sample data

julia> save("myfile.asdf", data)
```
"""
function fileio_save(f::File{format"ASDF"}, data)
    return write_file(f.filename, data)
end

fileio_save(f::File{format"ASDF"}, af::ASDFFile) = save(f, af.metadata)

@doc (@doc fileio_save) save

end
