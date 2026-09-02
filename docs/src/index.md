# ASDF.jl

A new [Advanced Scientific Data Format (ASDF)](https://asdf-standard.readthedocs.io/en/latest/index.html) package, written in Julia.

## Introduction

The ASDF file format is based on the human-readable [YAML](http://yaml.org/) standard, extended with efficient binary blocks to store array data. Basic arithmetic types (`Bool`, `Int`, `Float`, `Complex`) and `String` types are supported out of the box. Other types (structures) need to be declared to be supported.

ASDF supports arbitrary array strides, both C (Python) and Fortran (Julia) memory layouts, as well as compression. The YAML metadata can contain arbitrary information corresponding to scalars, arrays, or dictionaries.

The ASDF file format targets a similar audience as the [HDF5](https://www.hdfgroup.org/solutions/hdf5/) format.

## Installation

```julia-repl
pkg> add ASDF, OrderedCollections
```

```@repl intro
using ASDF, OrderedCollections
```

!!! note
    We use an `OrderedDict` from [OrderedCollections.jl](https://github.com/JuliaCollections/OrderedCollections.jl) to preserve the order of data on write and load, and to maximize compatibility with YAML.jl.

## Getting started

ASDF files are initially created as a dictionary with arbitrarily nested data:

```@example intro
af_payload = OrderedDict("field_1" => [5, 6, 7, 8], "field_2" => ["up", "down", "left", "right"], "field_3" => OrderedDict("field_3a" => ["apple", "orange", "pear"], "field_3b" => [1.0, 2.0, 3.0]))
```

ASDF.jl is registered with [FileIO.jl](https://juliaio.github.io/FileIO.jl/stable/), so this data can be written to the ASDF file format with the generic [`save`](@ref) function:

```@example intro
save("intro.asdf", af_payload)
```

The saved file contains the following human-readable contents:

!!! details "View file"
    ```@example intro
    read("intro.asdf", String) |> print
    ```

which can be loaded back with FileIO.jl's generic [`load`](@ref) function:

```@example intro
af = load("intro.asdf")
```

This is stored as an [`ASDF.ASDFFile`](@ref). To change the number of rows shown, pass this object to [`ASDF.info`](@ref):

```@example intro
ASDF.info(af; max_rows = 3)
```

It contains a `metadata` field, which is a new dictionary that merges information about this library (stored under the `asdf_library` key) with the original user-defined `af_payload` dictionary. For convenience, `af.metadata[<key>]` can be accessed directly as `af[key]`. Since the underlying data is a dictionary, it can be modified in the standard way:

```@example intro
af["field_1"] = [50, 60, 70, 80]
```

The convenience syntax can also be used to save the modified `ASDF.ASDFFile` object directly:

```@example intro
save("intro_modified.asdf", af)
```

!!! details "View file"
    ```@example intro
    read("intro_modified.asdf", String) |> print
    ```

## Array storage

By default, array data is written inline as a literal to the ASDF file. This can be stored and later accessed more efficiently by wrapping your data in an [`ASDF.NDArrayWrapper`](@ref). This allows for your data to be stored as a binary via the `inline = false` keyword (default), which can be further optimized by specifying a supported [compression algorithm](@ref ASDF.Compression) to use via the `compression` keyword:

```@example intro
af_payload = OrderedDict("meta" => OrderedDict("my" => OrderedDict("nested" => "metadata")), "data" => ASDF.NDArrayWrapper([1, 2, 3, 4]; compression = ASDF.C_Bzip2))

save("intro_compressed.asdf", af_payload)

af = load("intro_compressed.asdf")
```

!!! details "View file"
    ```julia-repl
    julia> read("intro_compressed.asdf", String) |> print
    #ASDF 1.0.0
    #ASDF_STANDARD 1.6.0
    # This is an ASDF file <https://asdf-standard.readthedocs.io/>
    %YAML 1.1
    %TAG ! tag:stsci.edu:asdf/
    ---
    !core/asdf-1.1.0
    meta:
      my:
        nested: "metadata"
    data: !core/ndarray-1.1.0
      source: 0
      shape:
        - 4
      datatype: "int64"
      byteorder: "little"
    asdf_library: !core/software-1.0.0
      name: "ASDF.jl"
      author: "Erik Schnetter <schnetter@gmail.com>"
      homepage: "https://github.com/JuliaAstro/ASDF.jl"
      version: "2.0.1"
    ...
    �BLK0   f�0xj�sq���r#ASDF BLOCK INDEX
    %YAML 1.1
    ---
    [463,]
    ...
    ```

Using `NDArrayWrapper` allows for the wrapped data to be lazily accessed as a strided view. To access the underlying data, use the `[]` (dereference) syntax:

```@example intro
af["data"][] == [1, 2, 3, 4]
```

## Tagged objects

Packages can extend [`ASDF.to_tree`](@ref) to serialize their own Julia types
wherever they occur in a larger ASDF document. See [Custom Julia
types](@ref) for the conversion contract and an example combining a custom
metadata object with a binary array.
