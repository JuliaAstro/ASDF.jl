# Introduction

*Adapted from [ADASS 2024 workshop](https://github.com/asdf-format/asdf-adass2024/blob/main/03_creating_asdf_files/Creating_ASDF_Files.ipynb).*

The ASDF file format is based on the human-readable [YAML](http://yaml.org/) standard, extended with efficient binary blocks to store array data. Basic arithmetic types (`Bool`, `Int`, `Float`, `Complex`) and `String` types are supported out of the box. Other types (structures) need to be declared to be supported.

ASDF supports arbitrary array strides, both C (Python) and Fortran (Julia) memory layouts, as well as compression. The YAML metadata can contain arbitrary information corresponding to scalars, arrays, or dictionaries.

The ASDF file format targets a similar audience as the [HDF5](https://www.hdfgroup.org/solutions/hdf5/) format.

## Getting started

ASDF files are initially created as a nested dictionary with your specified keys:

```@example intro
af_payload = Dict{Any, Any}( # To-do: see if type signature needs to be this general
    "meta" => Dict("my" => Dict("nested" => "metadata")),
    "data" => [1, 2, 3, 4],
)
```

Next, this dictionary can be written to the ASDF file format with `ASDF.write_file`:

```@example intro
using ASDF

ASDF.write_file("../data/my_file.asdf", af_payload)
```

which contains the following file contents:

```yaml
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
data:
  - 1
  - 2
  - 3
  - 4
asdf/library: !core/software-1.0.0
  version: "2.0.0"
  name: "ASDF.jl"
  author: "Erik Schnetter <schnetter@gmail.com>"
  homepage: "https://github.com/JuliaAstro/ASDF.jl"
...
#ASDF BLOCK INDEX
%YAML 1.1
---
[]
...
```

This file can be loaded back with `ASDF.load_file`:

```@example intro
af = ASDF.load_file("../data/my_file.asdf")
```

This creates an `ASDF.ASDFFile` object which contains a `meta` field. This is a new dictionary that merges information about this library (stored under the `asdf/library` key) with the original user-defined `af_payload` dictionary:

```@example intro
af.metadata
```

```@example intro
af.metadata["asdf/library"]
```

Since the underlying data is a dictionary, it can be modified in the standard way:

```@example intro
af.metadata["meta"]["my"]["nested2"] = "metadata2"

af.metadata
```

## Array storage

By default, array data is written inline as a literal to the ASDF file. This can be stored and later accessed more efficiently by wrapping your data in an `ASDF.NDArrayWrapper`. This allows for your data to be stored as a binary via the `inline = false` keyword. This can be further optimized by specifying a supported compression algorithm to use via the `compression` keyword. In either case, `NDArrayWrapper` data allows for your data to be accessed as a strided view.

```julia
ASDF.NDArrayWrapper(...; compression = ASDF.C_Bzip2) # The default
```

Access view `[]`

## Tagged objects

Comming soon. Supporting custom objects, extensions.
