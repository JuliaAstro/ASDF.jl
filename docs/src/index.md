# ASDF.jl

A new [Advanced Scientific Data Format (ASDF)](https://asdf-standard.readthedocs.io/en/latest/index.html) package, written in Julia.


## Quickstart


### Installation

```julia-repl
pkg> add ASDF, OrderedCollections
```

### Usage

```@repl
using ASDF, OrderedCollections

doc = OrderedDict(
    "field_1" => [5, 6, 7, 8],
    "field_2" => ["up", "down", "left", "right"],
    "field_3" => OrderedDict(
        "field_3a" => ["apple", "orange", "pear"],
        "field_3b" => [1.0, 2.0, 3.0],
    )
);

save("example.asdf", doc)

af = load("example.asdf")

ASDF.info(af; max_rows = 3)
```
