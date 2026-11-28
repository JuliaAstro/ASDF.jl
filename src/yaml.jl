"""
    asdf_datatype_yaml(dt) -> Union{String, Vector}

Serialize an ASDF datatype to its YAML-representable form.
"""
asdf_datatype_yaml

asdf_datatype_yaml(dt::AsciiDatatype) = ["ascii", dt.length]
asdf_datatype_yaml(dt::Ucs4Datatype) = ["ucs4", dt.length]

function asdf_datatype_yaml(dt::StructuredDatatype)
    return map(dt.fields) do f
        # To-do: replace with OrderedDict after https://github.com/JuliaAstro/ASDF.jl/pull/26
        Dict("name" => f.name, "datatype" => asdf_datatype_yaml(f.datatype), "byteorder" => string(f.byteorder))
    end
end

################################################################################

"""
    parse_asdf_datatype(val) -> Union{Datatype, AsciiDatatype, Ucs4Datatype, StructuredDatatype}

Parse a raw YAML datatype value into its corresponding ASDF datatype:

- `AbstractString` (e.g. `"float32"`) --> [`Datatype`](@ref)
- 2-element `AbstractVector` (e.g. `["ascii", 4]`) --> [`AsciiDatatype`](@ref) or [`Ucs4Datatype`](@ref)
- `AbstractVector` of dicts --> [`StructuredDatatype`](@ref)

Field-level `datatype` values within a structured dtype are parsed recursively,
so `["ascii", N]` is valid as a field type.

This is the inverse of [`asdf_datatype_yaml`](@ref).
"""
parse_asdf_datatype

parse_asdf_datatype(val::AbstractString) = Datatype(val)

function parse_asdf_datatype(val::AbstractVector)
    # 2-element [kind, length] form: ["ascii", 4] or ["ucs4", 4]
    if length(val) == 2 && val[1] isa AbstractString && val[2] isa Integer
        n = Int(val[2])
        if val[1] == "ascii"
            return AsciiDatatype(n)
        elseif val[1] == "ucs4"
            return Ucs4Datatype(n)
        else
            throw(ArgumentError("Unknown string datatype kind: $(val[1])"))
        end
    end
    fields = map(val) do d
        name = d["name"]::String
        dt = parse_asdf_datatype(d["datatype"])
        bo = haskey(d, "byteorder") ? Byteorder(d["byteorder"]::String) : host_byteorder
        StructuredField(name, dt, bo)
    end
    return StructuredDatatype(fields)
end

function make_construct_yaml_ndarray(block_headers::LazyBlockHeaders)
    # Track which too-old tags we have already warned about so each distinct tag is reported at
    # most once per load (a file may hold many ndarray nodes sharing one non-conformant tag).
    warned_tags = Set{String}()
    function construct_yaml_ndarray(constructor::YAML.Constructor, node::YAML.Node)
        # The whole tag may be the inline data itself, a nested list whose type is inferred.
        mapping = if node isa YAML.SequenceNode
            Dict{Any, Any}("data" => YAML.construct_sequence(constructor, node))
        else
            YAML.construct_mapping(constructor, node)
        end
        source = get(mapping, "source", nothing)::Union{Nothing, Integer}
        data = get(mapping, "data", nothing)::Union{Nothing, AbstractVector}
        shape = get(mapping, "shape", nothing)
        shape = shape isa Nothing ? nothing : int64_list(shape)
        datatype = get(mapping, "datatype", nothing) # No annotation needed, `parse_asdf_datatype` handles dispatch
        byteorder = get(mapping, "byteorder", nothing)::Union{Nothing, AbstractString}
        offset = get(mapping, "offset", nothing)::Union{Nothing, Integer}
        strides = get(mapping, "strides", nothing)
        strides = strides isa Nothing ? nothing : int64_list(strides)
        ndarray = NDArray(block_headers, source, data, shape, datatype, byteorder, offset, strides)
        # The datatype should be representable by the tag's ndarray schema version: `float16` (and
        # `complex32`) were only added in 1.1.0. `min_ndarray_version` is the single source of truth,
        # shared with the writer. A too-old tag is non-conformant, but other implementations (e.g.
        # asdf-cxx) emit it, so we warn and load leniently rather than reject the file.
        required = min_ndarray_version(ndarray.datatype)
        m = match(r"ndarray-(\d+\.\d+\.\d+)$", node.tag)
        if m !== nothing && VersionNumber(m[1]) < required && node.tag ∉ warned_tags
            push!(warned_tags, node.tag)
            @warn "ndarray tag is older than the schema version its datatype requires; loading leniently" tag = node.tag required = "!core/ndarray-$required"
        end
        return ndarray
    end
    return construct_yaml_ndarray
end

################################################################################

# Serialize a tagged node by emitting its tag right before the wrapped value, mirroring how
# `NDArrayWrapper` writes `!core/ndarray-1.1.0`. The YAML writer breaks the line after the key only
# for a *non-empty* block collection, so the tag goes on its own indented line there; for scalars
# and for empty collections (printed inline as `{}`/`[]`) the writer leaves us on the key's line,
# so the tag stays inline. Both forms parse back to a tagged node.
function YAML._print(io::IO, val::Union{TaggedMapping, TaggedSequence}, level::Int = 0, ignore_level::Bool = false)
    return if isempty(val.value)
        print(io, shorthand_tag(val.tag), " ")
        YAML._print(io, val.value, level, ignore_level)
    else
        print(io, YAML._indent(shorthand_tag(val.tag) * "\n", level, ignore_level))
        YAML._print(io, val.value, level)
    end
end
function YAML._print(io::IO, val::TaggedScalar, level::Int = 0, ignore_level::Bool = false)
    print(io, shorthand_tag(val.tag), " ")
    return YAML._print(io, val.value, level, ignore_level)
end

function YAML._print(io::IO, val::NDArray, level::Int = 0, ignore_level::Bool = false)
    # TODO: Get compression from underlying header block?
    return YAML._print(io, NDArrayWrapper(val[]; compression = C_None), level, ignore_level)
end

# YAML 1.1 only resolves a float written in exponential form when its exponent carries an explicit
# sign (`6.0e+23`, not `6.0e23`). Julia's `string` omits the `+`, and YAML.jl writes that verbatim,
# so strict parsers (e.g., PyYAML used by the Python impl of `asdf`) read such values back as plain
# *strings*, failing schema validation. Inserting the sign fixes the round-trip while keeping
# Julia's shortest round-trippable digits. (`NaN`/`Inf` keep YAML's `.nan`/`.inf` spellings.)
function yaml_float_string(val::AbstractFloat)
    isfinite(val) || return isnan(val) ? ".NaN" : (val > 0 ? ".inf" : "-.inf")
    return replace(string(val), r"[eE](?=[0-9])" => "e+")
end

# Rewrite inline ndarray data so every float is emitted in YAML-1.1-compliant form. Document
# metadata gets the same treatment from `_convert_tree`. The data nests one list per dimension, the
# first `shape` (last Julia) dimension outermost.
yaml_compliant(val::AbstractFloat) = YAMLScalar(yaml_float_string(val))
yaml_compliant(val::AbstractVector) = map(yaml_compliant, val)
yaml_compliant(val::AbstractArray) = map(yaml_compliant, eachslice(val; dims = ndims(val)))
yaml_compliant(val) = val

################################################################################

function make_construct_yaml_ndarray_chunk(block_headers::LazyBlockHeaders)
    function construct_yaml_ndarray_chunk(constructor::YAML.Constructor, node::YAML.Node)
        mapping = YAML.construct_mapping(constructor, node)
        start = int64_list(mapping["start"])
        ndarray = mapping["ndarray"]::NDArray
        return NDArrayChunk(start, ndarray)
    end
    return construct_yaml_ndarray_chunk
end

function make_construct_yaml_chunked_ndarray(block_headers::LazyBlockHeaders)
    function construct_yaml_chunked_ndarray(constructor::YAML.Constructor, node::YAML.Node)
        mapping = YAML.construct_mapping(constructor, node)
        shape = int64_list(mapping["shape"])
        datatype = mapping["datatype"]
        chunks = mapping["chunks"]::AbstractVector{NDArrayChunk}
        return ChunkedNDArray(shape, datatype, chunks)
    end
    return construct_yaml_chunked_ndarray
end

################################################################################

function YAML.write(file::ASDFFile)
    return "[ASDF file \"$(file.filename)\"]\n" * YAML.write(file.metadata)
end

################################################################################
################################################################################
################################################################################

function YAML._print(io::IO, val::ASDFLibrary, level::Int = 0, ignore_level::Bool = false)
    println(io, "!core/software-1.0.0")
    library = OrderedDict(:name => val.name, :author => val.author, :homepage => val.homepage, :version => val.version)
    return YAML._print(io, library, level, ignore_level)
end

function YAML._print(io::IO, val::NDArrayWrapper, level::Int = 0, ignore_level::Bool = false)
    datatype = infer_asdf_datatype(eltype(val.array))
    shape = collect(Int64, reverse(size(val.array)))
    if val.inline
        ndarray = OrderedDict(
            # Route inline data through the float pass so its elements get YAML-1.1 exponents too.
            # `collect` first: `eachslice` misindexes views of views with `Base.IdentityUnitRange` indices.
            :data => yaml_compliant(collect(val.array)),
            :shape => shape,
            :datatype => asdf_datatype_yaml(datatype), #string(Datatype(eltype(val.array))),
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
            :shape => shape,
            :datatype => asdf_datatype_yaml(datatype),
            :byteorder => string(host_byteorder::Byteorder),
            # :offset => 0::Integer,
            # :strides => ::Vector{Int64},
        )
    end
    # println(io, YAML._indent("-\n", level), "!core/chunked-ndarray-1.0.0")
    # Always emit ndarray-1.1.0: the file we write declares `#ASDF_STANDARD 1.6.0`, whose ndarray
    # schema is 1.1.0, and 1.1.0 is a superset of 1.0.0 so it represents every datatype we support
    # (`min_ndarray_version` never exceeds it). This keeps `float16` arrays valid and round-trips
    # 1.1.0-tagged arrays unchanged.
    # The tag ends its line, so the mapping always starts on the next one, indented. Passing on
    # `ignore_level` (set for a list item) would put its first key at column 0.
    println(io, "!core/ndarray-1.1.0")
    return YAML._print(io, ndarray, level)
end
