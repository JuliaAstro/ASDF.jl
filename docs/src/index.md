# ASDF.jl

A new [Advanced Scientific Data Format (ASDF)](https://asdf-standard.readthedocs.io/en/latest/index.html) package, written in Julia.


## Quickstart


### Installation

```julia-repl
pkg> add ASDF
```

### Usage

```julia
using ASDF
```

```julia
# Load
af = ASDF.load_file("<file.asdf>")
```

```julia
# Acess and modify
af.metadata["<key>"] = <val>
```

```julia
# Write
doc = Dict(<data>)
ASDF.write_file("<new_file.asdf>", doc)
```
