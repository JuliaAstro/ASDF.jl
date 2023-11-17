module ASDF2

using Blosc
# using Blosc2
using CodecBzip2
using MD5
using YAML
using CodecZlib

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

    did_reach_eof = false
    block_range = nothing
    while !did_reach_eof
        seek(io, pos)
        nb = readbytes!(io, buffer)
        did_reach_eof = eof(io)
        block_range = blockstart = findfirst(block_magic_token, @view buffer[1:(nb - 1)])
        block_range !== nothing && break
        pos += nb - (length(block_magic_token) - 1)
    end

    did_reach_eof && return nothing

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
        # elseif header.compression == Vector{UInt8}("bls2")
    elseif header.compression == Vector{UInt8}("bzp2")
        # TODO: Read directly from file
        data = transcode(Bzip2Decompressor, data)::AbstractVector{UInt8}
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
        @assert data === nothing || size(data) == shape
        @assert offset >= 0
        @assert length(shape) == length(strides)
        @assert all(shape .>= 0)
        @assert all(strides .> 0)
        return new(lazy_block_headers, source, data, shape, datatype, byteorder, offset, strides)
    end
end

function NDArray(
    lazy_block_headers::LazyBlockHeaders,
    source::Integer,
    shape::AbstractVector{<:Integer},
    datatype::Union{Datatype,AbstractString},
    byteorder::Union{Byteorder,AbstractString},
    offset::Integer=0,
    strides::Union{Nothing,<:AbstractVector{<:Integer}}=nothing,
)
    if datatype isa AbstractString
        datatype = Datatype(datatype)
    end
    if byteorder isa AbstractString
        byteorder = Byteorder(byteorder)
    end
    if strides isa Nothing
        strides = Int64[1 for sh in shape]
    end
    return NDArray(
        lazy_block_headers, Int64(source), nothing, Vector{Int64}(shape), datatype, byteorder, Int64(offset), Vector{Int64}(strides)
    )
end

function make_construct_yaml_ndarray(block_headers::LazyBlockHeaders)
    function construct_yaml_ndarray(constructor::YAML.Constructor, node::YAML.Node)
        mapping = YAML.construct_mapping(constructor, node)
        source = mapping["source"]::Integer
        shape = mapping["shape"]::AbstractVector{<:Integer}
        datatype = mapping["datatype"]::AbstractString
        byteorder = mapping["byteorder"]::AbstractString
        offset = mapping["offset"]::Integer
        strides = mapping["strides"]::AbstractVector{<:Integer}
        return NDArray(block_headers, source, shape, datatype, byteorder, offset, strides)
    end
    return construct_yaml_ndarray
end

function Base.getindex(ndarray::NDArray)
    @assert ndarray.source !== nothing
    data = read_block(ndarray.lazy_block_headers.block_headers[ndarray.source + 1])
    data = reinterpret(Type(ndarray.datatype), data)
    # TODO: take datatype, byteorder, offset, and strides into account
    data = reshape(data, ndarray.shape...)
    return data
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
# asdf_constructors["tag:stsci.edu:asdf/core/ndarray-1.0.0"] = construct_yaml_ndarray

function load_file(filename::AbstractString)
    io = open(filename, "r")
    lazy_block_headers = LazyBlockHeaders()
    construct_yaml_ndarray = make_construct_yaml_ndarray(lazy_block_headers)

    asdf_constructors′ = copy(asdf_constructors)
    asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-1.0.0"] = construct_yaml_ndarray

    metadata = YAML.load(io, asdf_constructors′)
    # lazy_block_headers.block_headers = find_all_blocks(io, position(io))
    lazy_block_headers.block_headers = find_all_blocks(io)
    return ASDFFile(filename, metadata, lazy_block_headers)
end

end
