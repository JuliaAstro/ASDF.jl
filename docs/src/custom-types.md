# Custom Julia types

ASDF documents often combine metadata, binary arrays, and objects owned by
domain packages. A package can make its types writable anywhere in an ASDF
document by extending [`ASDF.to_tree`](@ref):

```@example custom_types
using ASDF

struct Measurement
    value::Float64
    unit::String
end

function ASDF.to_tree(measurement::Measurement, context::ASDF.WriteContext)
    properties = Dict("value" => measurement.value, "unit" => measurement.unit)
    return ASDF.TaggedMapping("tag:example.org/measurement-1.0.0", properties)
end

document = Dict(
    "meta" => Dict("exposure" => Measurement(1200.0, "s")),
    "data" => ASDF.NDArrayWrapper(reshape(collect(1.0:12.0), 3, 4)),
)

save("custom-types.asdf", document)
```

`save` and [`ASDF.write_file`](@ref) recursively walk the complete document.
When they encounter a `Measurement`, Julia dispatch selects the method above.
ASDF then recursively converts custom objects contained in the returned node
before writing YAML and binary blocks.

The original document is not modified. The same conversion can be inspected
without writing a file:

```@example custom_types
node = ASDF.to_tree(Measurement(5.0, "m"))
node.tag
```

## Conversion contract

The public interface has two forms:

```julia
ASDF.to_tree(value)
ASDF.to_tree(value, context::ASDF.WriteContext)
```

The one-argument form recursively converts a value and is useful for inspecting
the ASDF representation. The two-argument form is the extension hook. Its
fallback returns the value unchanged.

A package method should return one of:

- a scalar, string, mapping, or array already supported by ASDF.jl;
- [`ASDF.TaggedMapping`](@ref), [`ASDF.TaggedSequence`](@ref), or
  [`ASDF.TaggedScalar`](@ref);
- [`ASDF.NDArrayWrapper`](@ref) for explicit inline or binary array storage.

Converter methods are shallow. They may return mappings or sequences containing
other custom objects; ASDF.jl converts those children automatically. Methods
should accept the [`ASDF.WriteContext`](@ref) but treat it as opaque.

ASDF.jl rejects cyclic mappings, arrays, or converter output because ASDF
reference serialization is not yet implemented.

## Optional ASDF support

When ASDF.jl is an optional dependency, define the method in a Julia package
extension that loads only when both packages are present:

```julia
module MyPackageASDFExt

using ASDF
using MyPackage

function ASDF.to_tree(value::MyPackage.CustomType, context::ASDF.WriteContext)
    return ASDF.TaggedMapping("tag:example.org/custom-1.0.0", Dict("value" => value.value))
end

end
```

This interface only controls writing. Loading an unknown tag with
`extensions = true` produces an `ASDF.TaggedMapping`, `ASDF.TaggedSequence`, or
`ASDF.TaggedScalar`; reconstructing package-owned objects and validating their
schemas require separate read-side support.
