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
| `C_Xz`           | `xz\\0\\0`     | ChunkCodecLibLzma.jl   | Highest compression ratio, slowest                            |
| `C_Zlib`         | `zlib`         | ChunkCodecLibZlib.jl   | Broad compatibility                                           |
| `C_Zstd`         | `zstd`         | ChunkCodecLibZstd.jl   | Best ratio/speed trade-off                                    |
"""
@enum Compression C_None C_Blosc C_Blosc2 C_Bzip2 C_Lz4 C_Xz C_Zlib C_Zstd

"""
    BlockHeader

Parsed representation of a single ASDF binary block header.

Every binary block in an ASDF file begins with a fixed-layout header that describes the
block's compression, size, and integrity checksum. `BlockHeader` captures all decoded fields
from that header, together with the `IO` handle and file position needed to subsequently
read the block's data payload.

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

|                                |                      |             |
| :--                            | :--                  | :--         |
| `[position]`                   | 4 bytes              | magic token |
| `[position + 4]`               | 2 bytes              | header_size  (big-endian UInt16) |
| `[position + 6]`               | header_size bytes    |      extended header fields |
| `[position + 6 + header_size]` | allocated_size bytes |  data payload |

The extended header (always 48 bytes in the current implementation) contains, in
order: `flags` (4 B), `compression` (4 B), `allocated_size` (8 B), `used_size` (8 B),
`data_size` (8 B), and `checksum` (16 B).

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

A mutable container holding the complete list of [`ASDF.BlockHeader`](@ref) values scanned
from an ASDF file, shared by reference with every [`ASDF.NDArray`](@ref) and
[`ASDF.ChunkedNDArray`](@ref) constructed during parsing.

# Reference sharing

Every [`ASDF.NDArray`](@ref) created during parsing of a given file holds a reference to
the same `LazyBlockHeaders` instance. When `ndarray[]` is called, it indexes into
`lazy_block_headers.block_headers` using the array's zero-based `source` field:

```julia
header = ndarray.lazy_block_headers.block_headers[ndarray.source + 1]
data   = ASDF.read_block(header)
```

Because `block_headers` is populated after all `NDArray` objects are constructed, no array
needs to be updated individually when block scanning completes. The shared mutable reference
propagates the result automatically.

# Mutability

`LazyBlockHeaders` is a `mutable struct` solely to allow `block_headers` to be assigned
after construction. The field is written exactly once per file load, immediately after
`YAML.load` within [`ASDF.load_file`](@ref) returns. It is never modified again during
normal use. Treat it as effectively immutable after [`load_file`](@ref) returns.
"""
mutable struct LazyBlockHeaders
    block_headers::Vector{BlockHeader}
    LazyBlockHeaders() = new(BlockHeader[])
end

################################################################################

"""
    ASDF.Byteorder

Represents the byte order of array data stored in a block. Available variants:

- `Byteorder_little` : Little-endian
- `Byteorder_big`: Big-endian
"""
@enum Byteorder Byteorder_little Byteorder_big
const byteorder_string_dict = Dict{Byteorder, String}(Byteorder_little => "little", Byteorder_big => "big")
const string_byteorder_dict = Dict{String, Byteorder}(val => key for (key, val) in byteorder_string_dict)

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

const datatype_string_dict = Dict{Datatype, String}(
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
const string_datatype_dict = Dict{String, Datatype}(val => key for (key, val) in datatype_string_dict)
const datatype_type_dict = Dict{Datatype, Type}(
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
const type_datatype_dict = Dict{Type, Datatype}(val => key for (key, val) in datatype_type_dict)

Datatype(str::AbstractString) = string_datatype_dict[str]
Base.string(datatype::Datatype) = datatype_string_dict[datatype]
Base.show(io::IO, datatype::Datatype) = show(io, string(datatype))

Base.Type(datatype::Datatype) = datatype_type_dict[datatype]
Datatype(type::Type) = type_datatype_dict[type]

asdf_datatype_yaml(dt::Datatype) = string(dt)  # "float32", "uint8", etc.

################################################################################

"""
    AsciiDatatype(length::Int)

An ASDF fixed-length ASCII string datatype, corresponding to the `["ascii", N]` form in
the ASDF datatype spec. Each element occupies exactly `length` bytes, one byte per
character (all codepoints < 128).

The corresponding `isbitstype` Julia type is `NTuple{N, UInt8}`. Byte order is irrelevant for
this type since each character is a single byte. When an array of this datatype is materialized
with [`Base.getindex(ndarray::NDArray)`](@ref), each element is presented as an
[`AsciiString`](@ref): a thin `AbstractString` view over those bytes, with identical contents.

See also: [`Ucs4Datatype`](@ref), [`AsciiString`](@ref), [`parse_asdf_datatype`](@ref).
"""
struct AsciiDatatype
    length::Int  # Bytes (1 per char)
end

"""
    Ucs4Datatype(length::Int)

An ASDF fixed-length UCS-4 string datatype, corresponding to the `["ucs4", N]` form in
the ASDF datatype spec. Each element occupies exactly `4 * length` bytes, with each
character encoded as a 4-byte UInt32 in the array's declared byte order.

The corresponding `isbitstype` Julia type is `NTuple{N, UInt32}`. When an array of this
datatype is materialized with [`Base.getindex(ndarray::NDArray)`](@ref), each element is
presented as a [`UCS4String`](@ref): a thin `AbstractString` view over those codepoints that
displays and behaves as a Julia string, with identical bytes.

See also: [`AsciiDatatype`](@ref), [`UCS4String`](@ref), [`parse_asdf_datatype`](@ref).
"""
struct Ucs4Datatype
    length::Int  # Characters (4 bytes each)
end

"""
    Base.Type(dt::AsciiDatatype) -> NTuple{N, UInt8}

Return the Julia `isbitstype` corresponding to an ASDF string datatype, suitable for use
with `reinterpret` and `sizeof`. `N` is the number of characters (`dt.length`).
"""
Base.Type(dt::AsciiDatatype) = NTuple{dt.length, UInt8}

"""
    Base.Type(dt::Ucs4Datatype)  -> NTuple{N, UInt32}

Return the Julia `isbitstype` corresponding to an ASDF string datatype, suitable for use
with `reinterpret` and `sizeof`. `N` is the number of characters (`dt.length`).
"""
Base.Type(dt::Ucs4Datatype) = NTuple{dt.length, UInt32}

################################################################################

"""
    StructuredField(name::String, datatype::Union{Datatype,AsciiDatatype,Ucs4Datatype}, byteorder::Byteorder)

A single named field within a [`StructuredDatatype`](@ref).
Corresponds to one entry in the ASDF `datatype` list when it takes the dict form:

```yaml
- {name: x,     datatype: float32,    byteorder: little}
- {name: label, datatype: [ascii, 8], byteorder: little}
```

`byteorder` specifies the byte order for this field specifically, overriding the ndarray's
top-level `byteorder`. For [`AsciiDatatype`](@ref) fields, `byteorder` is stored but
ignored during byte-swapping since single bytes have no endianness.
"""
struct StructuredField
    name::String
    datatype::Union{Datatype, AsciiDatatype, Ucs4Datatype}
    byteorder::Byteorder
end

"""
    StructuredDatatype(fields::Vector{StructuredField})

An ASDF compound datatype consisting of named fields, corresponding to
the list-of-dicts form of the `datatype` key in an ndarray:

```yaml
datatype:
- {name: x,     datatype: float32,    byteorder: little}
- {name: y,     datatype: float32,    byteorder: little}
- {name: label, datatype: [ascii, 4], byteorder: little}
```

The corresponding Julia type (returned by `Base.Type`) is a `NamedTuple` with one field per entry,
e.g., `@NamedTuple{x::Float32, y::Float32, label::NTuple{4,UInt8}}`.
This type is `isbitstype`, so `reinterpret`, `sizeof`, and `bswap` all work correctly on it.

See also: [`StructuredField`](@ref), [`parse_asdf_datatype`](@ref).
"""
struct StructuredDatatype
    fields::Vector{StructuredField}
end

"""
    Base.Type(sd::StructuredDatatype) -> NamedTuple type

Return the `NamedTuple` type corresponding to a structured ASDF datatype.
Field names and types are derived from `sd.fields` in order.

# Example

```julia
sd = StructuredDatatype([
    StructuredField("x",     Datatype_float32,  Byteorder_little),
    StructuredField("label", AsciiDatatype(4),  Byteorder_little),
])

Base.Type(sd) == @NamedTuple{x::Float32, label::NTuple{4,UInt8}}
```
"""
function Base.Type(sd::StructuredDatatype)
    names = Tuple(Symbol(f.name) for f in sd.fields)
    types = Tuple{(Type(f.datatype) for f in sd.fields)...}
    return NamedTuple{names, types}
end

################################################################################

"""
    NDArray

A lazily-materialized N-dimensional array stored in an ASDF file, either as a binary block or inline within the ASDF file.

`NDArray` is the in-memory representation of an `!core/ndarray-X.Y.Z` YAML node.
It holds the array's shape, type, and layout metadata, but defers reading and
decompressing block data until the array is explicitly materialized by calling
[`Base.getindex(ndarray::NDArray)`](@ref).

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
    source::Union{Nothing, Int64, AbstractString}
    data::Union{Nothing, AbstractArray}
    shape::Vector{Int64}
    datatype::Union{Datatype, StructuredDatatype, AsciiDatatype, Ucs4Datatype}
    byteorder::Byteorder
    offset::Int64
    strides::Vector{Int64} # stored in ASDF (Python/C) order, not in Julia (Fortran) order
    # mask

    function NDArray(
            lazy_block_headers::LazyBlockHeaders,
            source::Union{Nothing, Int64, AbstractString},
            data::Union{Nothing, AbstractArray},
            shape::Vector{Int64},
            datatype::Union{Datatype, StructuredDatatype, AsciiDatatype, Ucs4Datatype},
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
        source::Union{Nothing, Integer},
        data::Union{Nothing, AbstractArray},
        shape::Union{Nothing, AbstractVector{<:Integer}},
        datatype::Union{Nothing, Datatype, StructuredDatatype, AsciiDatatype, Ucs4Datatype, AbstractString, AbstractVector},
        byteorder::Union{Nothing, Byteorder, AbstractString},
        offset::Union{Nothing, Integer} = 0,
        strides::Union{Nothing, <:AbstractVector{<:Integer}} = nothing,
    )
    if source isa Integer
        source = Int64(source)
    end
    if datatype isa AbstractString || datatype isa AbstractVector
        datatype = parse_asdf_datatype(datatype)
    end
    if data isa AbstractVector
        # Inline data may leave out its `shape` and `datatype`, which are then inferred from it.
        if shape isa Nothing
            shape = inline_shape(data)
        end
        # Convert arrays of arrays into multi-dimensional arrays. The data nests one list per dimension with
        # the first `shape` (last Julia) dimension outermost, so its elements in order are column-major for
        # `reverse(shape)`. Unlike `stack`, flattening also handles empty and higher-dimensional data. Each
        # level must have the length `shape` gives and the leaves must be scalars; flattening alone would
        # accept data nested too shallowly or too deeply. Other arrays are already in Julia order.
        shape_error = ArgumentError("`shape` does not correctly describe the shape of `data`.")
        elements = Any[data]
        for n in shape
            all(item -> item isa AbstractVector && length(item) == n, elements) || throw(shape_error)
            elements = collect(Iterators.flatten(elements))
        end
        any(item -> item isa AbstractVector, elements) && throw(shape_error)
        # `null` marks a masked value, which is not supported yet.
        any(isnothing, elements) && throw(ArgumentError("masked inline values (`null`) are not supported yet"))
        if datatype isa Nothing
            datatype = inline_datatype(elements)
        end
        data = reshape(elements, Tuple(reverse(shape)))
    end
    (shape isa Nothing || datatype isa Nothing) && throw(ArgumentError("an ndarray without inline `data` needs `shape` and `datatype`"))
    if data !== nothing
        # Correct element type
        T = Type(datatype)
        data = T[inline_element(T, x) for x in data]
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
        # Calculate byte strides in C order, treating any zero-length dimension as
        # length 1 within this product only (not in `shape` itself). This matches NumPy's
        # convention for default C-contiguous strides (`PyArray_NewFromDescr`),
        # relied on by the reference Python `asdf` package. Without the clamp, a
        # zero-length dimension collapses the stride of every outer dimension whose
        # product includes it down to zero, which then fails the `strides` positivity
        # check below even though no data is ever read from a zero-size array. Negative
        # entries are left unclamped so the shape negativity check below still reports them
        # with its own clear error message. STScI Roman L2 `.asdf` products contain such
        # zero-shape arrays (e.g. `chisq`, `dumo`) with no explicit `strides` key.
        sz = itemsize(datatype)
        strides = [sz * prod(max.(shape[(i + 1):end], 1)) for i in eachindex(shape)]
    end
    return NDArray(
        lazy_block_headers, source, data, Vector{Int64}(shape), datatype, byteorder, Int64(offset), Vector{Int64}(strides)
    )
end

"""
    UCS4String{N} <: AbstractString

A fixed-width UCS-4 string of `N` characters, as materialized from an [`Ucs4Datatype`](@ref)
array. It wraps the raw `NTuple{N, UInt32}` codepoints and is `isbitstype` with an identical
memory layout, so it reinterprets to and from the on-disk block bytes exactly like the tuple
would. The difference is purely in presentation: a `UCS4String` *displays* and *behaves* as a
Julia string rather than as raw `UInt32` codepoints.

```jldoctest
julia> s = ASDF.UCS4String((UInt32('h'), UInt32('i'), UInt32(0)))  # null-padded
"hi"

julia> s == "hi"
true
```

As a fixed-width string, trailing null (`\\0`) padding is treated as unused and excluded from
the string's length and contents. The full `N` codepoints are retained internally so the
on-disk representation round-trips unchanged.

See also: [`AsciiString`](@ref).
"""
struct UCS4String{N} <: AbstractString
    codes::NTuple{N, UInt32}
end

"""
    AsciiString{N} <: AbstractString

A fixed-width ASCII string of `N` characters, as materialized from an [`AsciiDatatype`](@ref)
array. The single-byte analogue of [`UCS4String`](@ref): it wraps the raw `NTuple{N, UInt8}`
bytes and is `isbitstype` with an identical memory layout, reinterpreting to and from the
on-disk block bytes exactly like the tuple would, while *displaying* and *behaving* as a Julia
string rather than as raw `UInt8` bytes.

```jldoctest
julia> s = ASDF.AsciiString((UInt8('h'), UInt8('i'), UInt8(0)))  # null-padded
"hi"

julia> s == "hi"
true
```

As with `UCS4String`, trailing null (`\\0`) padding is excluded from the string's length and
contents, while the full `N` bytes are retained internally so the on-disk representation
round-trips unchanged.
"""
struct AsciiString{N} <: AbstractString
    codes::NTuple{N, UInt8}
end

# Both ASDF string views share the same fixed-width, null-padded, one-codeunit-per-character
# `AbstractString` interface; only the code-unit type differs.
const ASDFString = Union{UCS4String, AsciiString}

"""
    TaggedMapping{D} <: AbstractDict
    TaggedSequence{V} <: AbstractVector
    TaggedScalar <: AbstractString

A YAML node that carries a `tag` with no dedicated Julia representation, produced by
[`ASDF.load_file`](@ref). This covers two cases: recognized core container tags such as
`!core/software-1.0.0` and `!core/extension_metadata-1.0.0`, which are kept for their provenance
but otherwise behave as plain mappings; and, when loading with `extensions = true`, unrecognized
extension tags that would otherwise raise an error. Each behaves exactly like its wrapped `value`.
A mapping indexes and iterates as a dict, a sequence as a vector, a scalar as a string, while
retaining the original `tag` so the node round-trips unchanged through [`ASDF.write_file`](@ref).
The `tag` field must contain the full tag URI; the writer emits namespace shorthand where applicable.
"""
struct TaggedMapping{D <: AbstractDict} <: AbstractDict{Any, Any}
    tag::String
    value::D
end

@doc (@doc TaggedMapping)
struct TaggedSequence{V <: AbstractVector} <: AbstractVector{Any}
    tag::String
    value::V
end

@doc (@doc TaggedMapping)
struct TaggedScalar <: AbstractString
    tag::String
    value::String
end

# A scalar already rendered to its exact YAML text. Its `_print` emits that text verbatim, unlike a
# `String` (which YAML.jl would quote). We cannot instead override YAML.jl's own `_print(::Float64)`:
# replacing another module's method is rejected during precompilation, and doing it from `__init__`
# breaks downstream incremental compilation. So floats are rewritten to this additive type before
# writing (see `yaml_compliant`).
struct YAMLScalar
    text::String
end
YAML._print(io::IO, val::YAMLScalar, level::Int = 0, ignore_level::Bool = false) = println(io, val.text)

################################################################################

"""
    NDArrayChunk

A positioned tile within an [`ASDF.ChunkedNDArray`](@ref), pairing an [`ASDF.NDArray`](@ref)
with a zero-based origin that locates the tile in the parent array's coordinate space.

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

"""
    ChunkedNDArray

A logical N-dimensional array assembled from a collection of arbitrarily-positioned
[`ASDF.NDArrayChunk`](@ref) tiles, each backed by its own binary block or inline data.

`ChunkedNDArray` is the in-memory representation of a `!core/chunked-ndarray-1.X.Y` YAML
node. It defines the shape and element type of the full logical array, but defers all data
access to the individual chunks. The full array is only allocated and populated when
[`Base.getindex(ndarray::NDArray)`](@ref) is called.

# Fields

| Field      | Description |
| :--------- | :---------- |
| `shape`    | Dimensions of the full logical array in **Python/C (row-major) order**, outermost dimension first. All elements must be non-negative. The equivalent Julia shape is `reverse(shape)`. |
| `datatype` | Element type shared by all chunks. Convert to a Julia type with `Type(datatype)`. |
| `chunks`   | Ordered collection of tiles that together populate the logical array. Tiles are written in iteration order when materializing. Later tiles overwrite earlier ones in any overlapping region. |
"""
struct ChunkedNDArray
    shape::Vector{Int64}
    datatype::Union{Datatype, StructuredDatatype, AsciiDatatype, Ucs4Datatype}
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
        shape::AbstractVector{<:Integer}, datatype::Union{Datatype, StructuredDatatype, AsciiDatatype, Ucs4Datatype, AbstractString, AbstractVector}, chunks::AbstractVector{NDArrayChunk}
    )
    if datatype isa AbstractString || datatype isa AbstractVector
        datatype = Datatype(datatype)
    end
    return ChunkedNDArray(Vector{Int64}(shape), datatype, chunks)
end

################################################################################

"""
    ASDFFile

The in-memory representation of a loaded ASDF file, combining the parsed YAML metadata tree
with the binary block infrastructure needed to lazily materialize any array data it references.

# Fields

| Field                 | Description |
| :-------------------- | :---------- |
| `filename`            | Path of the file on disk, as passed to [`ASDF.load_file`](@ref). Used for display and diagnostics only. The file is not kept open after loading. |
| `metadata`            | The fully parsed YAML tree. Keys are strings matching the top-level YAML keys. Values may be any Julia type produced by the YAML constructors, including [`ASDF.NDArray`](@ref), [`ASDF.ChunkedNDArray`](@ref), nested `Dict`s, `Vector`s, and scalars. |
| `lazy_block_headers`  | All binary block headers found in the file, scanned once at load time. Shared by reference with every [`ASDF.NDArray`](@ref) in `metadata`, allowing them to locate and read their backing blocks on demand. |

`metadata` is stored as an `OrderedDict{Any, Any}` so top-level key order is preserved. The
constructor accepts any `AbstractDict` and builds this from its pairs, so a plain `Dict` may
be passed directly (it adopts that `Dict`'s iteration order); an already-ordered mapping
keeps its order.
"""
struct ASDFFile
    filename::AbstractString
    metadata::OrderedDict{Any, Any}
    lazy_block_headers::LazyBlockHeaders
end

ASDFFile(filename::AbstractString, metadata::AbstractDict, lazy_block_headers::LazyBlockHeaders) = ASDFFile(filename, OrderedDict{Any, Any}(metadata), lazy_block_headers)

struct ASDFTreeNode
    key::Any
    value::Any
end

################################################################################
################################################################################
################################################################################

"""
    ASDFLibrary

Software provenance metadata, serialized as a `!core/software-1.0.0 YAML` tag.
[`ASDF.write_file`] inserts an entry automatically under the key `"asdf_library"`
if one is not already present, using the package's own name, author, homepage, and version.
"""
struct ASDFLibrary
    name::AbstractString
    author::AbstractString
    homepage::AbstractString
    version::AbstractString
end

"""
    NDArrayWrapper

A write-side wrapper around a Julia array that carries compression and layout options.
Used as the value type when building a document dict for [`ASDF.write_file`](@ref).

Parameter     | Default   | Description                                                                                                        |
| :---------- | :-------- | :----------------------------------------------------------------------------------------------------------------- |
`compression` | `C_Bzip2` | Applied compression scheme                                                                                         |
`inline`      | `false`   | Embed data in YAML instead of a binary block. Needs at least one dimension and boolean, integer, or float elements |
`lz4_layout`  | `:block`  | `:block` for Python-compatible chunked LZ4, `:frame` for LZ4 frame format                                          |

!!! note
    If the compressed output is larger than the raw input, the block is stored uncompressed regardless of the chosen compression.
"""
struct NDArrayWrapper
    array::AbstractArray
    compression::Compression
    inline::Bool
    lz4_layout::Symbol
end
function NDArrayWrapper(array::AbstractArray; compression::Compression = C_Bzip2, inline::Bool = false, lz4_layout::Symbol = :block)
    return NDArrayWrapper(array, compression, inline, lz4_layout)
end
Base.getindex(val::NDArrayWrapper) = val.array

"""
    Blocks

Module-level accumulator that collects [`ASDF.NDArrayWrapper`](@ref) values and
their corresponding file positions during a single call to [`ASDF.write_file`](@ref).

`Blocks` acts as a two-phase write buffer. In the first phase, as the YAML tree is
serialized, each non-inline [`ASDF.NDArrayWrapper`](@ref) appends itself to `arrays` and
reserves a sequential source index. In the second phase, [`ASDF.write_file`](@ref) iterates
over `arrays`, compresses and writes each block to disk, and records the resulting file
offsets in `positions`. The finalized `positions` vector is then written as the ASDF block
index at the end of the file.

!!! warning "Not thread-safe"
    A single instance of `Blocks` is held in the module-level constant `ASDF.blocks`.
    Because this global state is mutated by [`ASDF.write_file`](@ref), concurrent calls to
    `write_file` from multiple threads will corrupt each other's block lists. Do not call
    `write_file` concurrently.

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
