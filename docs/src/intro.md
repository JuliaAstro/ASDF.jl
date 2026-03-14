# Introduction

*Adapted from [ADASS 2024 workshop](https://github.com/asdf-format/asdf-adass2024/blob/main/03_creating_asdf_files/Creating_ASDF_Files.ipynb).*

## Getting started

Created via a regular dictionary:

```@example intro
af_payload = Dict{Any, Any}( # To-do: see if type signature needs to be this general
    "meta" => Dict("my" => Dict("nested" => "metadata")),
    "data" => [1, 2, 3, 4],
)
```

Write and load with `ASDF.write_file` and `ASDF.load_file`, respectively:

```@example intro
using ASDF

ASDF.write_file("../data/my_asdf.asdf", af_payload)

af = ASDF.load_file("../data/my_asdf.asdf")
```

This contains a `meta` field, which is a dictionary that merges information about this library with `af_payload`:

```@example intro
af.metadata
```

```@example intro
af.metadata["asdf/library"]
```

## Tagged objects

Supporting custom objects, extensions.

## Array storage

```julia
ASDF.NDArrayWrapper(...; inline, compression)
```
