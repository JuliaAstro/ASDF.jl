# Custom Julia types

ASDF documents often combine metadata, binary arrays, and objects owned by
domain packages. A package can make its types writable anywhere in an ASDF
document by extending [`ASDF.to_tree`](@ref):

```@example custom_types
using ASDF
using OrderedCollections

struct Measurement
    value::Float64
    unit::String
end

function ASDF.to_tree(measurement::Measurement)
    properties = OrderedDict("value" => measurement.value, "unit" => measurement.unit)
    return ASDF.TaggedMapping("tag:example.org/measurement-1.0.0", properties)
end

document = OrderedDict(
    "meta" => OrderedDict("exposure" => Measurement(1200.0, "s")),
    "data" => ASDF.NDArrayWrapper(reshape(collect(1.0:12.0), 3, 4)),
)

save("custom-types.asdf", document)
```

`save` and [`ASDF.write_file`](@ref) recursively walk the complete document.
When they encounter a `Measurement`, Julia dispatch selects the method above.
ASDF then recursively converts custom objects contained in the returned node
before writing YAML and binary blocks.

The original document is not modified. Calling the hook directly inspects its
shallow representation:

```@example custom_types
node = ASDF.to_tree(Measurement(5.0, "m"))
node.tag
```

## Conversion contract

Packages extend the one-argument `ASDF.to_tree(value)` hook. The fallback
returns `value` unchanged.

A package method should return one of:

- `nothing`, a boolean, integer, float, string, symbol, `Date`, or `DateTime`;
- a mapping with boolean, integer, string, or symbol keys, a vector, tuple, or
  named tuple;
- [`ASDF.TaggedMapping`](@ref), [`ASDF.TaggedSequence`](@ref), or
  [`ASDF.TaggedScalar`](@ref);
- [`ASDF.NDArrayWrapper`](@ref) for explicit inline or binary array storage.

Converter methods are shallow. They may return mappings or sequences containing
other custom objects; the writer converts those children automatically and
redispatches when a converter delegates to another custom type. Converters
should not call `to_tree` recursively themselves.

Symbols are written as strings. Unsupported leaves and mapping keys produce an
error instead of being silently stringified. Multidimensional arrays must be
wrapped in `NDArrayWrapper`; metadata sequences are vectors. ASDF.jl rejects
cyclic mappings, sequences, or converter output because ASDF reference
serialization is not yet implemented.

## Optional ASDF support

When ASDF.jl is an optional dependency, define the method in a Julia package
extension that loads only when both packages are present:

```julia
module MyPackageASDFExt

using ASDF
using MyPackage

function ASDF.to_tree(value::MyPackage.CustomType)
    return ASDF.TaggedMapping("tag:example.org/custom-1.0.0", Dict("value" => value.value))
end

end
```

This interface only controls writing. Loading an unknown tag with
`extensions = true` produces an `ASDF.TaggedMapping`, `ASDF.TaggedSequence`, or
`ASDF.TaggedScalar`; reconstructing package-owned objects and validating their
schemas require separate read-side support.
