# ASDF.jl

A new [Advanced Scientific Data Format (ASDF)](https://asdf-standard.readthedocs.io/en/latest/index.html) package, written in Julia.


## Quickstart

```julia
using ASDF
```

```julia
# Load
af = ASDF.load_file("<file.asdf>")
```

```julia
# Modify
af.metadata["<key>"] = <val>
```

```julia
# Write
ASDF.write_file("<new_file.asdf>")
```
