module ASDF

using ChunkCodecLibBlosc: BloscCodec, BloscEncodeOptions
using ChunkCodecLibBzip2: BZ2Codec, BZ2EncodeOptions
using ChunkCodecLibLz4: LZ4BlockCodec, LZ4FrameCodec, LZ4BlockEncodeOptions, LZ4FrameEncodeOptions
using ChunkCodecLibLzma: XZCodec, XZEncodeOptions
using ChunkCodecLibZlib: ZlibCodec, ZlibEncodeOptions
using ChunkCodecLibZstd: ZstdCodec, ZstdEncodeOptions, decode, encode
using MD5: md5
using PkgVersion: PkgVersion
using StridedViews: StridedView
using YAML: YAML
using OrderedCollections: OrderedDict
using FileIO: @format_str, File, load, save
using AbstractTrees: AbstractTrees
using Dates: Date, DateTime

export load, save

include("types.jl")
include("yaml.jl")

################################################################################

const software_name = "ASDF.jl"
const software_author = PkgVersion.@Author "Erik Schnetter <schnetter@gmail.com>"
const software_homepage = "https://github.com/JuliaAstro/ASDF.jl"
const software_version = string(PkgVersion.@Version)

################################################################################

const compression_keys = Dict{Compression, Vector{UInt8}}(
    C_None => UInt8[0, 0, 0, 0],
    C_Blosc => Vector{UInt8}("blsc"),
    C_Blosc2 => Vector{UInt8}("bls2"),
    C_Bzip2 => Vector{UInt8}("bzp2"),
    C_Lz4 => Vector{UInt8}("lz4\0"),
    C_Xz => Vector{UInt8}("xz\0\0"),
    C_Zlib => Vector{UInt8}("zlib"),
    C_Zstd => Vector{UInt8}("zstd"),
)
if !all(length(val) == 4 for val in values(compression_keys))
    error("Invalid entry in `compression_keys`, please ensure all values have length 4.")
end
const compression_enums = Dict{Vector{UInt8}, Compression}(
    value => key for (key, value) in compression_keys
)

################################################################################

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
    return UInt8[
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

    STREAMED = Bool(flags & 0x01)
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
function find_all_blocks(io::IO, pos::Int64 = Int64(0); validate_checksum::Bool)
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
    elseif compression == C_Lz4
        data = decode_Lz4(data)
    else
        if compression == C_Blosc
            codec = BloscCodec()
        elseif compression == C_Bzip2
            codec = BZ2Codec()
        elseif compression == C_Xz
            codec = XZCodec()
        elseif compression == C_Zlib
            codec = ZlibCodec()
        elseif compression == C_Zstd
            codec = ZstdCodec()
        else
            error("Invalid compression format found: $compression")
        end
        d_size = Int64(header.data_size)
        data = decode(codec, data; max_size = d_size, size_hint = d_size)
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
                data[3] == 0x4D && data[4] == 0x18
        )
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
            compressed_chunk_size = Int(big2native_U32(@view data[pos:(pos + 3)]))
            pos += 4
            # Inner lz4.block store_size=True prefix: little-endian uncompressed size
            uncompressed_chunk_size = Int(little2native_U32(@view data[pos:(pos + 3)]))
            pos += 4
            # Raw LZ4 block payload (compressed_chunk_size includes the 4-byte LE prefix)
            payload_len = compressed_chunk_size - 4
            payload = @view data[pos:(pos + payload_len - 1)]
            pos += payload_len
            append!(out, decode(LZ4BlockCodec(), payload; max_size = uncompressed_chunk_size, size_hint = uncompressed_chunk_size))
        end

        return out
    end
end

################################################################################

"""
    host_byteorder

Native byte order of the running machine, detected at load time. Defined by [`ASDF.Byteorder`](@ref).
"""
const host_byteorder = reinterpret(UInt8, UInt16[1])[1] == 1 ? Byteorder_little : Byteorder_big

################################################################################

"""
    itemsize(datatype) -> Int

Number of bytes one element of `datatype` occupies in a block. ASDF, like NumPy, packs
the fields of a [`StructuredDatatype`](@ref) record back to back, while the `NamedTuple` from
`Type(datatype)` may pad them for alignment, so a record's `itemsize` can be smaller than its `sizeof`.
"""
itemsize(dt) = sizeof(Type(dt))
itemsize(dt::StructuredDatatype) = sum(itemsize(f.datatype) for f in dt.fields; init = 0)

# A function barrier for records assembled from per-field columns.
# Typed, so an empty array still has eltype `NT` rather than whatever inference finds.
assemble_records(::Type{NT}, columns::Vararg{Any, N}) where {NT, N} = NT[NT(values) for values in zip(columns...)]

"""
    uses_float16(dt) -> Bool

Whether the datatype `dt` (including any nested field of a [`StructuredDatatype`](@ref))
is or contains a `Float16`. The `float16` scalar datatype was only added to the ndarray
schema in version 1.1.0, so such arrays must be tagged `!core/ndarray-1.1.0` rather than
`!core/ndarray-1.0.0`. `complex32` is `Complex{Float16}`, so it counts too.
"""
uses_float16(dt::Datatype) = dt === Datatype_float16 || dt === Datatype_complex32
uses_float16(::Union{AsciiDatatype, Ucs4Datatype}) = false
uses_float16(dt::StructuredDatatype) = any(uses_float16(f.datatype) for f in dt.fields)

"""
    min_ndarray_version(datatype) -> VersionNumber

Lowest `!core/ndarray-X.Y.Z` schema version that can represent `datatype`: `float16` (and
`complex32`, which contains it) require 1.1.0; every other datatype is valid from 1.0.0. Used by
the reader to reject arrays whose tag is too old for their datatype. (The writer always emits
1.1.0, the schema version of the `#ASDF_STANDARD 1.6.0` files it produces.)
"""
min_ndarray_version(datatype) = uses_float16(datatype) ? v"1.1.0" : v"1.0.0"

################################################################################

# The shape of nested inline lists, read along their first elements; the constructor checks every level.
function inline_shape(data::AbstractVector)
    shape = Int64[]
    level = data
    while level isa AbstractVector
        push!(shape, length(level))
        isempty(level) && break
        level = first(level)
    end
    return shape
end

# The datatype of inline data given without one, by the ndarray schema's inference rules.
function inline_datatype(elements)
    # At least 1, as in NumPy: all-empty strings would otherwise give zero-byte elements and strides.
    any(x -> x isa AbstractString, elements) && return Ucs4Datatype(max(1, maximum(length ∘ string, elements)))
    any(x -> x isa Complex, elements) && return Datatype_complex128
    any(x -> x isa AbstractFloat, elements) && return Datatype_float64
    any(x -> x isa Integer && !(x isa Bool), elements) && return Datatype_int64
    # NumPy also makes an empty array `float64`.
    return isempty(elements) ? Datatype_float64 : Datatype_bool8
end

# An inline element as a value of the datatype's Julia type. `ascii` and `ucs4` elements are YAML
# strings, stored as their character codes padded with nulls to the datatype's length.
inline_element(T::Type, x) = convert(T, x)
function inline_element(T::Type{<:Tuple{Vararg{Union{UInt8, UInt32}}}}, s::AbstractString)
    n = fieldcount(T)
    codes = [UInt32(c) for c in s]
    length(codes) <= n || throw(ArgumentError("inline string $(repr(s)) is longer than the $n characters of its datatype"))
    eltype(T) === UInt8 && any(>(0x7f), codes) && throw(ArgumentError("inline string $(repr(s)) is not ASCII"))
    return T(ntuple(i -> i <= length(codes) ? codes[i] : 0, n))
end
# Any string makes the whole array a string array, so numbers among the strings become strings too.
inline_element(T::Type{<:Tuple{Vararg{Union{UInt8, UInt32}}}}, x::Real) = inline_element(T, string(x))

# YAML reads an empty list, such as the `shape: []` of a 0-dimensional array, as a `Vector{Any}`.
int64_list(list) = Int64[x::Integer for x in list::AbstractVector]

"""
    Base.getindex(ndarray::NDArray)

Returns the fully materialized array. See [`ASDF.NDArray`](@ref) for definitions.
When block-backed (`source` !== `nothing`), this reads and decompresses the block, applies
offset and strides via a [`StridedViews.StridedView`](https://github.com/QuantumKitHub/StridedViews.jl),
reinterprets bytes to `Type(datatype)`, and byte-swaps if `byteorder != host_byteorder`.
The returned array satisfies:

```julia
size(result) == Tuple(reverse(ndarray.shape))
eltype(result) == ASDF.materialized_eltype(ndarray.datatype)
```

For the `ucs4` and `ascii` string datatypes, [`materialized_eltype`](@ref) is a thin
`AbstractString` view over the characters ([`UCS4String`](@ref) / [`AsciiString`](@ref);
see [`stringify_data`](@ref)). For all other datatypes, `eltype(result) == Type(ndarray.datatype)`
and additionally, when the array has at least one element,
`sizeof(eltype) .* strides(result) == Tuple(reverse(ndarray.strides))`
along every dimension with more than one element.
The exception is a structured datatype whose `NamedTuple` pads its fields for alignment:
the block packs them (see [`itemsize`](@ref)), so the records are read field by field into a
dense array in Julia's own layout. (A dimension of length 1 has no well-defined stride,
there is no pair of adjacent elements to space apart along it, and in a zero-element array
no dimension does, so `reshape`/`reinterpret` are free to report any value there; such
strides are excluded from this check.)
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
        block = read_block(ndarray.lazy_block_headers.block_headers[ndarray.source + 1])
        # Handle strides and offset.
        # Do this before imposing the datatype because strides are given in bytes.
        typesize = itemsize(ndarray.datatype)
        # `StridedView` reads `block` with `@inbounds`, so a corrupt or crafted
        # `offset`, `shape`, or `strides` must not address bytes past the end of the block.
        # An empty array reads nothing. `big` keeps huge values from overflowing past the check.
        if all(>(0), ndarray.shape)
            nbytes = big(ndarray.offset) + sum(big.(ndarray.shape .- 1) .* ndarray.strides; init = big(0)) + typesize
            nbytes <= length(block) || throw(ArgumentError("ndarray `offset`, `shape`, and `strides` address $nbytes bytes of a $(length(block))-byte block"))
        end
        # View the elements' bytes starting `offset` bytes into the block as values of type `T`: add a
        # leading dimension for the bytes of a `T`, impose `T`, then remove that dimension again.
        dims = Tuple(Int.(reverse(ndarray.shape)))
        strides = Tuple(Int.(reverse(ndarray.strides)))
        view_as(T, offset) = reshape(reinterpret(T, StridedView(block, (sizeof(T), dims...), (1, strides...), Int(offset))), dims)
        NT = Type(ndarray.datatype)
        data = if typesize == sizeof(NT)
            view_as(NT, ndarray.offset)
        else
            # The block packs the fields of a structured record, which Julia pads for alignment, so
            # Read each field at its packed offset and assemble the records.
            fields = (ndarray.datatype::StructuredDatatype).fields
            sizes = [itemsize(f.datatype) for f in fields]
            columns = [view_as(Type(f.datatype), ndarray.offset + o) for (f, o) in zip(fields, cumsum(sizes) .- sizes)]
            assemble_records(NT, columns...)
        end
        # Correct byteorder if necessary.
        # Do this after imposing the datatype since byteorder depends on the datatype.
        data = correct_byteorder(data, ndarray.datatype, ndarray.byteorder)
    else
        # Unreachable branch. Caught in the constructor for `NDArray`. This branch would imply that
        # `ndarray` is in invalid state; neither `source` nor `data` is given.
        @assert false # COV_EXCL_LINE
    end

    # Check array layout
    @assert size(data) == Tuple(reverse(ndarray.shape)) # `data` conforms to specified `ndarray.shape`
    @assert eltype(data) == Type(ndarray.datatype) # `data` matches type specified by `ndarray.datatype`
    # A dimension of length 1 has no meaningful stride (there is no pair of adjacent elements
    # to space apart along it), and in an empty array no dimension does — Julia reports
    # stride 0 along any dimension whose faster-varying dimensions include a zero length.
    # Only compare strides where they are meaningful. Records assembled from padded fields are a dense
    # copy in Julia's layout, so their strides follow that layout rather than the block's.
    computed_strides = sizeof(eltype(data)) .* Base.strides(data)
    expected_strides = Tuple(reverse(ndarray.strides))
    data_shape = size(data)
    if sizeof(eltype(data)) == itemsize(ndarray.datatype) && !isempty(data) && any(data_shape[i] > 1 && computed_strides[i] != expected_strides[i] for i in eachindex(data_shape))
        error("`data` has different stride from `ndarray.strides`")
    end

    # Present `ucs4`/`ascii` data as `UCS4String`/`AsciiString` rather than raw tuples of
    # codepoints. Done after the layout checks above, which rely on the `isbitstype` tuple
    # representation; the views are a zero-copy `reinterpret` sharing those bytes, so this is
    # display/behavior only.
    data = stringify_data(data, ndarray.datatype)

    return data::AbstractArray
end

"""
    correct_byteorder(data, dt::Union{Datatype, AsciiDatatype, Ucs4Datatype}, byteorder::Byteorder)

Applies any necessary byteswap to the `data` within `ndarray` after it has been
reinterpreted as `Type(dt)`, where `dt = ndarray.datatype`.

`byteorder` is the ndarray-level [`Byteorder`](@ref).
"""
correct_byteorder

function correct_byteorder(data, ::Datatype, byteorder::Byteorder)
    if byteorder != host_byteorder
        map!(bswap, data, data)
    end
    return data
end

function correct_byteorder(data, dt::StructuredDatatype, ::Byteorder)
    needs_swap = any(
        !(f.datatype isa AsciiDatatype) && f.byteorder != host_byteorder
            for f in dt.fields
    )
    if needs_swap
        data = map(data) do elem
            swapped = map(dt.fields, Tuple(elem)) do field, val
                if field.datatype isa AsciiDatatype
                    val  # bytes have no endianness
                elseif field.byteorder != host_byteorder
                    bswap(val)
                else
                    val
                end
            end
            Type(dt)(swapped)
        end
    end
    return data
end

function correct_byteorder(data, ::AsciiDatatype, ::Byteorder)
    return data
end

function correct_byteorder(data, ::Ucs4Datatype, byteorder::Byteorder)
    if byteorder != host_byteorder
        data = map(elem -> map(bswap, elem), data)
    end
    return data
end

# Number of significant characters, i.e. `N` minus any trailing null padding.
function significant_length(s::ASDFString)
    n = length(s.codes)
    @inbounds while n > 0 && s.codes[n] == 0
        n -= 1
    end
    return n
end

Base.ncodeunits(s::ASDFString) = significant_length(s)
Base.codeunit(::UCS4String) = UInt32
Base.codeunit(::AsciiString) = UInt8
function Base.codeunit(s::ASDFString, i::Integer)
    @boundscheck 1 <= i <= ncodeunits(s) || throw(BoundsError(s, i))
    return @inbounds s.codes[i]
end
Base.isvalid(s::ASDFString, i::Integer) = 1 <= i <= ncodeunits(s)
Base.length(s::ASDFString) = ncodeunits(s)
function Base.iterate(s::ASDFString, i::Int = 1)
    # State is the code-unit index, per the `AbstractString` interface (`getindex` calls
    # `iterate(s, i::Integer)`), so the significant length is rechecked each step.
    i > ncodeunits(s) && return nothing
    u = s.codes[i]
    isvalid(Char, u) || error("$(typeof(s)) contains an invalid Unicode codepoint $(repr(u)) at index $i")
    return (Char(u), i + 1)
end

"""
    stringify_data(data, datatype) -> AbstractArray

Present a materialized [`Ucs4Datatype`](@ref) array as [`UCS4String`](@ref)s, and an
[`AsciiDatatype`](@ref) array as [`AsciiString`](@ref)s, instead of raw tuples of codepoints.
For any other datatype the data is returned unchanged. The string views are `isbitstype` with
the same layout as the backing tuples, so this is a zero-copy `reinterpret`; only display and
behavior change, and writing is unaffected.
"""
stringify_data(data, datatype) = data
stringify_data(data, dt::Ucs4Datatype) = reinterpret(materialized_eltype(dt), data)
stringify_data(data, dt::AsciiDatatype) = reinterpret(materialized_eltype(dt), data)

"""
    materialized_eltype(datatype) -> Type

Julia element type produced by materializing an array of the given ASDF `datatype`. This is
[`UCS4String{N}`](@ref UCS4String) for [`Ucs4Datatype`](@ref), [`AsciiString{N}`](@ref AsciiString)
for [`AsciiDatatype`](@ref), and `Type(datatype)` otherwise.
"""
materialized_eltype(dt) = Type(dt)
materialized_eltype(dt::Ucs4Datatype) = UCS4String{dt.length}
materialized_eltype(dt::AsciiDatatype) = AsciiString{dt.length}

# `keys`, `values`, `haskey`, etc. fall back to these via the `AbstractDict` interface.
# `get` is delegated explicitly because the `haskey`/`get` fallbacks need a 3-arg `get`.
Base.getindex(m::TaggedMapping, k) = getindex(m.value, k)
Base.get(m::TaggedMapping, k, default) = get(m.value, k, default)
Base.length(m::TaggedMapping) = length(m.value)
Base.iterate(m::TaggedMapping, state...) = iterate(m.value, state...)
# Mutation is delegated to the wrapped value so a loaded node can be edited in place (e.g.
# `af["asdf_library"]["version"] = "3"`) while retaining the tag; without these, `AbstractDict`
# has no mutating fallbacks and such edits would `MethodError`.
Base.setindex!(m::TaggedMapping, v, k) = (setindex!(m.value, v, k); m)
Base.delete!(m::TaggedMapping, k) = (delete!(m.value, k); m)
Base.empty!(m::TaggedMapping) = (empty!(m.value); m)
Base.get(f::Base.Callable, m::TaggedMapping, k) = get(f, m.value, k)
Base.get!(m::TaggedMapping, k, default) = get!(m.value, k, default)
Base.get!(f::Base.Callable, m::TaggedMapping, k) = get!(f, m.value, k)
Base.pop!(m::TaggedMapping, k) = pop!(m.value, k)
Base.pop!(m::TaggedMapping, k, default) = pop!(m.value, k, default)
# A `TaggedMapping` wraps an `OrderedDict`, so dropping the tag back to one preserves insertion
# order. Define the conversion explicitly to bypass OrderedCollections' generic (and deprecated)
# `AbstractDict`→`OrderedDict` path, which fires when the top-level document tag is stored into
# `ASDFFile.metadata`.
Base.convert(::Type{OrderedDict{Any, Any}}, m::TaggedMapping) = OrderedDict{Any, Any}(m.value)

Base.size(s::TaggedSequence) = size(s.value)
Base.getindex(s::TaggedSequence, i::Int) = getindex(s.value, i)
Base.IndexStyle(::Type{<:TaggedSequence}) = IndexLinear()
# As with `TaggedMapping`, delegate mutation so a loaded sequence stays editable in place. The
# `AbstractArray` `setindex!` fallback errors for a generic wrapped vector, and the resizing methods
# have no fallback at all.
Base.setindex!(s::TaggedSequence, v, i::Int) = (setindex!(s.value, v, i); s)
Base.push!(s::TaggedSequence, items...) = (push!(s.value, items...); s)
Base.pop!(s::TaggedSequence) = pop!(s.value)
Base.insert!(s::TaggedSequence, i::Integer, v) = (insert!(s.value, i, v); s)
Base.deleteat!(s::TaggedSequence, i) = (deleteat!(s.value, i); s)
Base.resize!(s::TaggedSequence, n::Integer) = (resize!(s.value, n); s)
Base.empty!(s::TaggedSequence) = (empty!(s.value); s)

Base.ncodeunits(s::TaggedScalar) = ncodeunits(s.value)
Base.codeunit(s::TaggedScalar) = codeunit(s.value)
Base.codeunit(s::TaggedScalar, i::Integer) = codeunit(s.value, i)
Base.isvalid(s::TaggedScalar, i::Integer) = isvalid(s.value, i)
Base.iterate(s::TaggedScalar, i::Integer = 1) = iterate(s.value, i)

# Render a tag for output. An ASDF file declares `%TAG ! tag:stsci.edu:asdf/`, so tags under that
# namespace are written in the `!core/...` shorthand (matching how the writer emits
# `!core/asdf-1.1.0`, `!core/ndarray-...`, etc.); any other tag uses the verbose `!<uri>` form.
# Both parse back to the same tag.
function shorthand_tag(tag::AbstractString)
    prefix = "tag:stsci.edu:asdf/"
    return startswith(tag, prefix) ? "!" * chopprefix(tag, prefix) : "!<" * tag * ">"
end

const complex_tag = "tag:stsci.edu:asdf/core/complex-1.0.0"

# Read a `!core/complex-1.0.0` value such as `1-1j`, `2.5J`, `-1` or `(1+2i)`: a real part, an
# imaginary part marked by a `j`, `J`, `i` or `I` suffix, or both joined by the imaginary part's sign.
function parse_complex(text::AbstractString)
    s = strip(text)
    if startswith(s, '(') && endswith(s, ')')
        s = strip(s[2:(end - 1)])
    end
    last(s) in "jJiI" || return complex(parse(Float64, s))
    imaginary = chop(s)
    # The imaginary part starts at the last sign that neither opens the value nor follows an exponent.
    bytes = codeunits(imaginary)
    k = findlast(i -> i > 1 && bytes[i] in UInt8.(('+', '-')) && !(bytes[i - 1] in UInt8.(('e', 'E'))), eachindex(bytes))
    k === nothing && return complex(0.0, parse(Float64, imaginary))
    return complex(parse(Float64, SubString(imaginary, 1, prevind(imaginary, k))), parse(Float64, SubString(imaginary, k)))
end

# Write a complex number in the `!core/complex-1.0.0` form, with the `i` suffix its schema recommends.
function complex_string(z::Complex)
    part(x) = isnan(x) ? "nan" : isinf(x) ? (x > 0 ? "inf" : "-inf") : string(x)
    # Convert before taking the sign and magnitude: `abs(typemin(Int64))` overflows and stays negative.
    x, y = Float64(real(z)), Float64(imag(z))
    return string(part(x), signbit(y) ? "-" : "+", part(abs(y)), "i")
end

"""
    ASDF.to_tree(value)

Convert one package-owned value to an ASDF-compatible tree node.

Packages extend this shallow hook for their own types. A method must return a
supported scalar, mapping, vector, [`ASDF.TaggedMapping`](@ref),
[`ASDF.TaggedSequence`](@ref), [`ASDF.TaggedScalar`](@ref), or
[`ASDF.NDArrayWrapper`](@ref). ASDF recursively converts values nested in the
returned node while writing a file. The fallback returns `value` unchanged.
"""
to_tree(value) = value

function _convert_tree(value, active = Base.IdSet{Any}())
    # Plain scalars have neither hooks nor children, so they skip the cycle guard.
    value isa Union{Nothing, Bool, Int, Float64, String} && return _convert_tree_children(value, active)
    value in active && throw(ArgumentError("cyclic ASDF write conversion involving $(typeof(value)) is not supported"))
    length(active) < 1000 || throw(ArgumentError("ASDF write conversion is nested more than 1000 levels deep at $(typeof(value)); check for an ASDF.to_tree method that never returns a supported node"))
    push!(active, value)
    try
        converted = to_tree(value)
        return converted === value ? _convert_tree_children(value, active) : _convert_tree(converted, active)
    finally
        delete!(active, value)
    end
end

_convert_tree_children(value::Union{Nothing, Integer, AbstractString, Date, DateTime}, active) = value
_convert_tree_children(value::AbstractFloat, active) = YAMLScalar(yaml_float_string(value))
_convert_tree_children(value::Symbol, active) = String(value)
_convert_tree_children(value::Complex, active) = TaggedScalar(complex_tag, complex_string(value))
_convert_tree_children(value::NDArray, active) = value
_convert_tree_children(value::NamedTuple, active) = OrderedDict{Any, Any}(String(key) => _convert_tree(item, active) for (key, item) in pairs(value))
_convert_tree_children(value::Tuple, active) = [_convert_tree(item, active) for item in value]

function _convert_tree_children(value::TaggedMapping, active)
    return TaggedMapping(value.tag, _convert_tree_children(value.value, active))
end

function _convert_tree_children(value::TaggedSequence, active)
    return TaggedSequence(value.tag, _convert_tree_children(value.value, active))
end

function _convert_tree_children(value::AbstractDict, active)
    converted = OrderedDict{Any, Any}()
    for (key, item) in value
        key isa Symbol && (key = String(key))
        key isa Union{Integer, AbstractString} || throw(ArgumentError("ASDF mapping key $(repr(key)) has unsupported type $(typeof(key)); keys must be booleans, integers, strings, or symbols"))
        # `:a` and `"a"` are distinct Julia keys but the same YAML key.
        haskey(converted, key) && throw(ArgumentError("ASDF mapping key $(repr(key)) occurs more than once after key normalization"))
        converted[key] = _convert_tree(item, active)
    end
    return converted
end

_convert_tree_children(value::AbstractVector, active) = [_convert_tree(item, active) for item in value]
function _convert_tree_children(value::AbstractArray, active)
    throw(ArgumentError("ASDF metadata arrays must be vectors; wrap $(typeof(value)) in ASDF.NDArrayWrapper to write an N-dimensional array"))
end
function _convert_tree_children(value, active)
    throw(ArgumentError("value of type $(typeof(value)) is not supported by the ASDF writer; convert it to a supported value or, for a type you own, define ASDF.to_tree(::$(typeof(value)))"))
end

################################################################################

"""
    Base.getindex(chunked_ndarray::ChunkedNDArray)

Allocates a dense array of shape `reverse(shape)` and fills it by calling `chunk.ndarray[]` for each chunk, placing the result at the correct offset.
"""
function Base.getindex(chunked_ndarray::ChunkedNDArray)
    shape = chunked_ndarray.shape
    datatype = materialized_eltype(chunked_ndarray.datatype)
    data = Array{datatype}(undef, reverse(shape)...)
    for chunk in chunked_ndarray.chunks
        start = CartesianIndex(reverse(chunk.start .+ 1)...)
        shape = CartesianIndex(reverse(chunk.start + chunk.ndarray.shape)...)
        data[start:shape] .= chunk.ndarray[]
    end
    return data::AbstractArray
end

# Chunked output is not implemented, so a loaded chunked array is written back as one contiguous
# block, the same way `YAML._print(::NDArray)` writes a loaded plain array.
_convert_tree_children(value::ChunkedNDArray, active) = NDArrayWrapper(value[]; compression = C_None)

################################################################################

Base.getindex(af::ASDFFile, key) = af.metadata[key]
Base.setindex!(af::ASDFFile, value, key) = (af.metadata[key] = value)

# Only mappings are walked; vectors (data arrays and lists of containers alike) are leaf nodes,
# summarized by their shape rather than expanded element-by-element.
AbstractTrees.children(n::ASDFTreeNode) =
    n.value isa ASDFFile ? [ASDFTreeNode(k, v) for (k, v) in n.value.metadata] :
    n.value isa AbstractDict ? [ASDFTreeNode(k, v) for (k, v) in n.value] :
    ()

# Compact, module-unqualified type label for a vector node.
vector_typelabel(v::Vector) = "Vector{$(nameof(eltype(v)))}"
vector_typelabel(v::AbstractVector) = string(nameof(typeof(v)))

AbstractTrees.printnode(io::IO, n::ASDFTreeNode) =
    n.key === nothing ? print(io, basename(n.value.filename)) :
    n.value isa AbstractDict ? print(io, n.key, "::", nameof(typeof(n.value))) :
    n.value isa NDArray ? print(io, n.key, "::", nameof(typeof(n.value)), " | shape = ", n.value.shape, ", datatype = ", materialized_eltype(n.value.datatype)) :
    n.value isa AbstractVector ? print(io, n.key, "::", vector_typelabel(n.value), " | shape = ", size(n.value)) :
    print(io, n.key, "::", typeof(n.value), " | ", n.value)

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
└─ asdf_library::TaggedMapping
   ├─ name::String | ASDF.jl
   ├─ author::String | Erik Schnetter <schnetter@gmail.com>
   ├─ homepage::String | https://github.com/JuliaAstro/ASDF.jl
   └─ version::String | 2.1.2
```
"""
function info(io::IO, af::ASDFFile; max_rows = 20)
    root = ASDFTreeNode(nothing, af)
    # Render the full tree, then count/cut by the *rendered* lines. Counting nodes separately (e.g.
    # via `PostOrderDFS`) overcounts whenever `print_tree` collapses deep subtrees, making the
    # "more rows" tally larger than the number of lines actually withheld.
    buf = IOBuffer()
    AbstractTrees.print_tree(buf, root)
    lines = split(String(take!(buf)), '\n', keepempty = false)

    if length(lines) ≤ max_rows
        foreach(l -> println(io, l), lines)
    else
        foreach(l -> println(io, l), Iterators.take(lines, max_rows))
        println(io, "  ⋮  (", length(lines) - max_rows, ") more rows")
    end
    return
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
| `extensions`        | When `true`, unknown YAML tags are parsed leniently (as maps, sequences, or scalars) instead of raising an error, and a warning naming each unrecognized tag is emitted (once per distinct tag). The tag is retained (see [`ASDF.TaggedMapping`](@ref)) so the node round-trips unchanged on write. |
| `validate_checksum` | When `true`, each block's MD5 checksum is verified against the stored value                                      |

Block data is located lazily. Block headers are scanned after the YAML is parsed, and array data (`ndarray`) is read only when [`Base.getindex(ndarray::NDArray)`](@ref) is called, i.e., `ndarray[]`.

!!! note "File handle lifetime"
    The file handle opened by `load_file` is retained for the lifetime of the returned [`ASDF.ASDFFile`](@ref) so that block data can be read on demand. Do not move, truncate, or overwrite the source file while any [`ASDF.NDArray`](@ref) from it may still be accessed.
"""
function load_file(filename::AbstractString; extensions = false, validate_checksum = true)
    # These core container tags carry no behavior of their own (we just want their mapping
    # contents), but the tag itself is provenance worth keeping, so wrap them in a `TaggedMapping`
    # that round-trips the tag on write.
    tagged_map_constructor = (constructor, node) -> TaggedMapping(node.tag, YAML.construct_mapping(OrderedDict{Any, Any}, constructor, node))
    asdf_constructors = copy(YAML.default_yaml_constructors)
    delete!(asdf_constructors, "tag:yaml.org,2002:map")  # Let dicttype= handle plain maps
    asdf_constructors["tag:stsci.edu:asdf/core/asdf-1.1.0"] = tagged_map_constructor
    asdf_constructors["tag:stsci.edu:asdf/core/software-1.0.0"] = tagged_map_constructor
    asdf_constructors["tag:stsci.edu:asdf/core/extension_metadata-1.0.0"] = tagged_map_constructor
    asdf_constructors[complex_tag] = (constructor, node) -> parse_complex(YAML.construct_scalar(constructor, node))

    if extensions
        # Use fallbacks for now. Track which unrecognized tags we have already
        # warned about so each distinct tag is reported at most once per load.
        warned_tags = Set{Any}()
        asdf_constructors[nothing] = (constructor, node) -> begin
            if node.tag ∉ warned_tags
                push!(warned_tags, node.tag)
                @warn "Unrecognized tag encountered while loading; falling back to a generic representation" tag = node.tag
            end
            # Wrap in a `Tagged*` type so the unrecognized tag is retained and round-trips on write.
            if node isa YAML.MappingNode
                return TaggedMapping(node.tag, YAML.construct_mapping(OrderedDict{Any, Any}, constructor, node))
            elseif node isa YAML.SequenceNode
                return TaggedSequence(node.tag, YAML.construct_sequence(constructor, node))
            else
                return TaggedScalar(node.tag, YAML.construct_scalar(constructor, node))
            end
        end
    end

    io = open(filename, "r")
    lazy_block_headers = LazyBlockHeaders()
    construct_yaml_ndarray = make_construct_yaml_ndarray(lazy_block_headers)
    construct_yaml_chunked_ndarray = make_construct_yaml_chunked_ndarray(lazy_block_headers)
    construct_yaml_ndarray_chunk = make_construct_yaml_ndarray_chunk(lazy_block_headers)

    asdf_constructors′ = copy(asdf_constructors)
    # One constructor handles every ndarray schema version we accept; the per-datatype minimum
    # is enforced inside it via `min_ndarray_version`.
    for v in (v"1.0.0", v"1.1.0")
        asdf_constructors′["tag:stsci.edu:asdf/core/ndarray-$v"] = construct_yaml_ndarray
    end
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
└─ asdf_library::TaggedMapping
   ├─ name::String | ASDF.jl
   ├─ author::String | Erik Schnetter <schnetter@gmail.com>
   ├─ homepage::String | https://github.com/JuliaAstro/ASDF.jl
   └─ version::String | 2.1.2
```
"""
function fileio_load(f::File{format"ASDF"}; kwargs...)
    return load_file(f.filename; kwargs...)
end

@doc (@doc fileio_load) load

################################################################################
################################################################################
################################################################################

_convert_tree_children(value::ASDFLibrary, active) = value

# Reject arrays that cannot be stored inline here, before `write_file` opens the file.
function _convert_tree_children(value::NDArrayWrapper, active)
    value.inline || return value
    array = value.array
    # The ndarray schema requires inline `data` to be a list, and Python `asdf` also refuses.
    ndims(array) == 0 && throw(ArgumentError("a 0-dimensional array cannot be stored inline; use `inline = false`"))
    # Inline elements are YAML scalars, which YAML.jl reads back only as booleans, `Int64`s, and floats.
    eltype(array) <: Union{Integer, AbstractFloat} || throw(ArgumentError("an array of $(eltype(array)) cannot be stored inline; use `inline = false`"))
    eltype(array) <: UInt64 && any(>(typemax(Int64)), array) && throw(ArgumentError("`UInt64` values above `typemax(Int64)` cannot be stored inline; use `inline = false`"))
    return value
end

function Base.empty!(blocks::Blocks)
    empty!(blocks.arrays)
    empty!(blocks.positions)
    return nothing
end
Base.isempty(blocks::Blocks) = isempty(blocks.arrays) && isempty(blocks.positions)
# Unfortunately we need a global variable.
# This means that `write_file` is not thread-safe.
const blocks::Blocks = Blocks()

"""
    infer_asdf_datatype(T::Type) --> Union{Datatype, AsciiDatatype, Ucs4Datatype, StructuredDatatype}

Infer the ASDF datatype from a Julia element type, used when writing arrays:

- `NTuple{N, UInt8}` or [`AsciiString{N}`](@ref AsciiString) --> [`AsciiDatatype(N)`](@ref AsciiDatatype)
- `NTuple{N, UInt32}` or [`UCS4String{N}`](@ref UCS4String) --> [`Ucs4Datatype(N)`](@ref Ucs4Datatype)
- `NamedTuple` --> [`StructuredDatatype`](@ref) with fields inferred recursively
- Any other type --> [`Datatype`](@ref) via the existing `type_datatype_dict` lookup

Errors if `T` is not representable as an ASDF datatype.

See also: [`asdf_datatype_yaml`](@ref).
"""
function infer_asdf_datatype(T::Type)::Union{Datatype, AsciiDatatype, Ucs4Datatype, StructuredDatatype}
    if T <: NTuple{N, UInt8} where {N}
        return AsciiDatatype(fieldcount(T))
    elseif T <: NTuple{N, UInt32} where {N}
        return Ucs4Datatype(fieldcount(T))
    elseif T <: NamedTuple
        fields = map(fieldnames(T), fieldtypes(T)) do name, FT
            StructuredField(string(name), infer_asdf_datatype(FT), host_byteorder)
        end
        return StructuredDatatype(collect(fields))
    else
        return Datatype(T)  # existing dict lookup, errors on unknown types
    end
end

# `UCS4String{N}`/`AsciiString{N}` round-trip to the datatypes they were materialized from; the
# width `N` is the type parameter, recovered directly by dispatch (the inverse of `materialized_eltype`).
infer_asdf_datatype(::Type{UCS4String{N}}) where {N} = Ucs4Datatype(N)
infer_asdf_datatype(::Type{AsciiString{N}}) where {N} = AsciiDatatype(N)

# The bytes of a vector's elements as stored in a block. Julia pads the fields of a `NamedTuple`
# record for alignment and the block packs them (see `itemsize`), so padded records are packed field
# by field.
block_bytes(array::AbstractVector) = reinterpret(UInt8, array)
function block_bytes(array::AbstractVector{T}) where {T <: NamedTuple}
    dt = infer_asdf_datatype(T)
    itemsize(dt) == sizeof(T) && return reinterpret(UInt8, array)
    bytes = Matrix{UInt8}(undef, itemsize(dt), length(array))
    row = 0
    for (k, field) in enumerate(dt.fields)
        n = itemsize(field.datatype)
        bytes[(row + 1):(row + n), :] = reshape(reinterpret(UInt8, fieldtype(T, k)[record[k] for record in array]), n, :)
        row += n
    end
    return vec(bytes)
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
        append!(
            out, [
                (uncompressed_size >>> 0x00) & 0xff,
                (uncompressed_size >>> 0x08) & 0xff,
                (uncompressed_size >>> 0x10) & 0xff,
                (uncompressed_size >>> 0x18) & 0xff,
            ]
        )

        # Raw LZ4 block payload
        append!(out, compressed_payload)
        offset = chunk_end + 1
    end

    return out
end

"""
    write_file(filename::AbstractString, document::AbstractDict)

Writes an ASDF file to disk. `document` may contain custom Julia objects with
[`ASDF.to_tree`](@ref) methods, including objects nested inside mappings or
vectors. Values may also include [`NDArrayWrapper`](@ref) instances, which are
serialized as binary blocks with appropriate compression.

Layout of the output file:

1. ASDF/YAML header (`#ASDF 1.0.0, #ASDF_STANDARD 1.6.0, %YAML 1.1`)
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
    # Build the output tree as an `OrderedDict` regardless of the input dict's concrete type, so
    # insertion order is preserved (for a `TaggedMapping` document, `merge` would otherwise fall
    # back to an unordered `Dict` and drop the order). The provenance entry is stamped last.
    full_document = OrderedDict{Any, Any}(document)
    full_document["asdf_library"] = library
    # Convert package-owned objects and normalize floats before block collection.
    full_document = _convert_tree(full_document)

    # Serialize the YAML part before opening the file, so a value that fails to print (such as an array
    # with no ASDF datatype) leaves an existing file intact. Blocks are still written straight to the
    # file, so large arrays are not held in memory twice.
    tree = IOBuffer()
    println(
        tree,
        """#ASDF 1.0.0
        #ASDF_STANDARD 1.6.0
        # This is an ASDF file <https://asdf-standard.readthedocs.io/>
        %YAML 1.1
        %TAG ! tag:stsci.edu:asdf/
        ---
        !core/asdf-1.1.0""",
    )
    YAML.write(tree, full_document)
    println(tree, "...")

    # Write the file. The do-block closes `io` even if writing a block fails,
    # so a leaked stream can't later flush stale bytes over the file.
    open(filename, "w") do io
        write(io, take!(tree))

        # Write blocks
        if !isempty(blocks.arrays)
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

                # Write block
                # TODO: create function write_block

                input = array.array
                # Make dense (contiguous) if necessary
                input = input isa DenseArray ? input : Array(input)
                # Reshape to 1D
                input = reshape(input, :)
                # Reinterpret as UInt8, packing structured records
                input = block_bytes(input)

                data_size = UInt64(length(input))

                # TODO: Write directly to file
                if array.compression == C_None
                    data = input
                elseif array.compression == C_Lz4 && array.lz4_layout == :block
                    data = encode_Lz4_block(input)
                    #data = encode(LZ4BlockEncodeOptions(), input) # Not compatible with Python asdf
                else
                    if array.compression == C_Blosc
                        encode_options = BloscEncodeOptions(; clevel = 9, doshuffle = 2, typesize = itemsize(infer_asdf_datatype(eltype(array.array))), compressor = "zstd")
                    elseif array.compression == C_Bzip2
                        encode_options = BZ2EncodeOptions(; blockSize100k = 9)
                    elseif array.compression == C_Lz4 && array.lz4_layout == :frame
                        encode_options = LZ4FrameEncodeOptions(; compressionLevel = 12, blockSizeID = 7)
                    elseif array.compression == C_Xz
                        encode_options = XZEncodeOptions(; preset = UInt32(6))
                    elseif array.compression == C_Zlib
                        encode_options = ZlibEncodeOptions(; level = 9)
                    elseif array.compression == C_Zstd
                        encode_options = ZstdEncodeOptions(; compressionLevel = 22)
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
                data::Union{DenseArray, Base.ReinterpretArray{<:Any, <:Any, <:Any, <:DenseArray}}

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
        end
    end

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
