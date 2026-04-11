# Introduction

*Adapted from [ADASS 2024 workshop](https://github.com/asdf-format/asdf-adass2024/blob/main/03_creating_asdf_files/Creating_ASDF_Files.ipynb).*

The ASDF file format is based on the human-readable [YAML](http://yaml.org/) standard, extended with efficient binary blocks to store array data. Basic arithmetic types (`Bool`, `Int`, `Float`, `Complex`) and `String` types are supported out of the box. Other types (structures) need to be declared to be supported.

ASDF supports arbitrary array strides, both C (Python) and Fortran (Julia) memory layouts, as well as compression. The YAML metadata can contain arbitrary information corresponding to scalars, arrays, or dictionaries.

The ASDF file format targets a similar audience as the [HDF5](https://www.hdfgroup.org/solutions/hdf5/) format.

## Getting started

ASDF files are initially created as a dictionary with arbitrarily nested data:

```jldoctest intro
julia> using OrderedCollections

julia> af_payload = OrderedDict("field_1" => [5, 6, 7, 8], "field_2" => ["up", "down", "left", "right"], "field_3" => OrderedDict("field_3a" => ["apple", "orange", "pear"], "field_3b" => [1.0, 2.0, 3.0]));
```

!!! note
    We use an `OrderedDict` from [OrderedCollections.jl](https://github.com/JuliaCollections/OrderedCollections.jl) to preserve the order of data on write and load, and to maximize compatibility with YAML.jl. For a potential alternative using [Dictionaries.jl](https://github.com/andyferris/Dictionaries.jl), see this [experimental branch](https://github.com/JuliaAstro/ASDF.jl/tree/dictionaries).

ASDF.jl is registered with [FileIO.jl](https://juliaio.github.io/FileIO.jl/stable/), so this data can be written to the ASDF file format with the generic [`save`](@ref) function:

```jldoctest intro
julia> using ASDF

julia> save("intro.asdf", af_payload)
```

The saved file contains the following human-readable contents:

!!! details "View file"
    ```jldoctest intro
    julia> read("intro.asdf", String) |> print
    #ASDF 1.0.0
    #ASDF_STANDARD 1.2.0
    # This is an ASDF file <https://asdf-standard.readthedocs.io/>
    %YAML 1.1
    %TAG ! tag:stsci.edu:asdf/
    ---
    !core/asdf-1.1.0
    field_1:
      - 5
      - 6
      - 7
      - 8
    field_2:
      - "up"
      - "down"
      - "left"
      - "right"
    field_3:
      field_3a:
        - "apple"
        - "orange"
        - "pear"
      field_3b:
        - 1.0
        - 2.0
        - 3.0
    asdf/library: !core/software-1.0.0
      name: "ASDF.jl"
      author: "Erik Schnetter <schnetter@gmail.com>"
      homepage: "https://github.com/JuliaAstro/ASDF.jl"
      version: "2.0.0"
    ...
    #ASDF BLOCK INDEX
    %YAML 1.1
    ---
    []
    ...
    ```

which can be loaded back with FileIO.jl's generic [`load`](@ref) function:

```jldoctest intro
julia> af = load("intro.asdf")
intro.asdf
├─ field_1::Vector{Int64} | shape = (4,)
├─ field_2::Vector{String} | shape = (4,)
├─ field_3::String
│  ├─ field_3a::Vector{String} | shape = (3,)
│  └─ field_3b::Vector{Float64} | shape = (3,)
└─ asdf/library::String
   ├─ author::String | Erik Schnetter <schnetter@gmail.com>
   ├─ homepage::String | https://github.com/JuliaAstro/ASDF.jl
   ├─ name::String | ASDF.jl
   └─ version::String | 2.0.0
```

This is stored as an [`ASDF.ASDFFile`](@ref). To change the number of rows shown, pass this object to [`ASDF.info`](@ref):

```jldoctest intro
julia> ASDF.info(af; max_rows = 3)
intro.asdf
├─ field_1::Vector{Int64} | shape = (4,)
├─ field_2::Vector{String} | shape = (4,)
  ⋮  (8) more rows
```

It contains a `metadata` field, which is a new dictionary that merges information about this library (stored under the `asdf/library` key) with the original user-defined `af_payload` dictionary. For convenience, `af.metadata[<key>]` can be accessed directly as `af[key]`. Since the underlying data is a dictionary, it can be modified in the standard way:

```jldoctest intro
julia> af["field_1"] = [50, 60, 70, 80];

julia> af["field_1"]
4-element Vector{Int64}:
 50
 60
 70
 80
```

The convenience syntax can also be used to save the modified `ASDF.ASDFFile` object directly:

```jldoctest intro
julia> save("intro_modified.asdf", af)
```

!!! details "View file"
    ```jldoctest intro
    julia> read("intro_modified.asdf", String) |> print
    #ASDF 1.0.0
    #ASDF_STANDARD 1.2.0
    # This is an ASDF file <https://asdf-standard.readthedocs.io/>
    %YAML 1.1
    %TAG ! tag:stsci.edu:asdf/
    ---
    !core/asdf-1.1.0
    field_1:
      - 50
      - 60
      - 70
      - 80
    field_2:
      - "up"
      - "down"
      - "left"
      - "right"
    field_3:
      field_3a:
        - "apple"
        - "orange"
        - "pear"
      field_3b:
        - 1.0
        - 2.0
        - 3.0
    asdf/library: !core/software-1.0.0
      name: "ASDF.jl"
      author: "Erik Schnetter <schnetter@gmail.com>"
      homepage: "https://github.com/JuliaAstro/ASDF.jl"
      version: "2.0.0"
    ...
    #ASDF BLOCK INDEX
    %YAML 1.1
    ---
    []
    ...
    ```

## Array storage

By default, array data is written inline as a literal to the ASDF file. This can be stored and later accessed more efficiently by wrapping your data in an [`ASDF.NDArrayWrapper`](@ref). This allows for your data to be stored as a binary via the `inline = false` keyword (default), which can be further optimized by specifying a supported [compression algorithm](@ref ASDF.Compression) to use via the `compression` keyword:

```jldoctest intro
julia> af_payload = OrderedDict("meta" => OrderedDict("my" => OrderedDict("nested" => "metadata")), "data" => ASDF.NDArrayWrapper([1, 2, 3, 4]; compression = ASDF.C_Bzip2));

julia> save("intro_compressed.asdf", af_payload)

julia> af = load("intro_compressed.asdf")
intro_compressed.asdf
├─ meta::String
│  └─ my::String
│     └─ nested::String | metadata
├─ data::ASDF.NDArray | shape = [4]
└─ asdf/library::String
   ├─ author::String | Erik Schnetter <schnetter@gmail.com>
   ├─ homepage::String | https://github.com/JuliaAstro/ASDF.jl
   ├─ name::String | ASDF.jl
   └─ version::String | 2.0.0
```

!!! details "View file"
    ```julia-repl
    julia> read("intro_compressed.asdf", String) |> print
    #ASDF 1.0.0
    #ASDF_STANDARD 1.2.0
    # This is an ASDF file <https://asdf-standard.readthedocs.io/>
    %YAML 1.1
    %TAG ! tag:stsci.edu:asdf/
    ---
    !core/asdf-1.1.0
    meta:
      my:
        nested: "metadata"
    data: !core/ndarray-1.0.0
      source: 0
      shape:
        - 4
      datatype: "int64"
      byteorder: "little"
    asdf/library: !core/software-1.0.0
      name: "ASDF.jl"
      author: "Erik Schnetter <schnetter@gmail.com>"
      homepage: "https://github.com/JuliaAstro/ASDF.jl"
      version: "2.0.0"
    ...
    �BLK0   f�0xj�sq���r#ASDF BLOCK INDEX
    %YAML 1.1
    ---
    [463,]
    ...
    ```

Using `NDArrayWrapper` allows for the wrapped data to be lazily accessed as a strided view. To access the underlying data, use the `[]` (dereference) syntax:

```jldoctest intro
julia> af["data"][]
4-element reshape(reinterpret(Int64, ::StridedViews.StridedView{UInt8, 2, Memory{UInt8}, typeof(identity)}), 4) with eltype Int64:
 1
 2
 3
 4
```

## Tagged objects

Come back soon to see how custom Julia objects can be handled in ASDF.jl.
