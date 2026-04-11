# ASDF.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliaastro.org/ASDF/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliaastro.org/ASDF.jl/dev)

[![CI](https://github.com/JuliaAstro/ASDF.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaAstro/ASDF.jl/actions/workflows/CI.yml)
[![PkgEval](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/A/ASDF.svg)](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/report.html)
[![codecov](https://codecov.io/gh/JuliaAstro/ASDF.jl/graph/badge.svg)](https://codecov.io/gh/JuliaAstro/ASDF.jl)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A new [Advanced Scientific Data Format (ASDF)](https://asdf-standard.readthedocs.io/en/latest/index.html) package, written in Julia.

## Quickstart

```julia
using ASDF

af = load("jwst.asdf"; extensions = true)
jwst.asdf
├─ asdf_library::String
│  ├─ author::String | The ASDF Developers
│  ├─ homepage::String | http://github.com/asdf-format/asdf
│  ├─ name::String | asdf
│  └─ version::String | 3.2.0
├─ history::String
│  └─ extensions::Vector{OrderedCollections.OrderedDict{Any, Any}} | shape = (6,)
├─ _fits_hash::String | 93cf4256596bd7a6d20913c3d0f6e1ab9d3a8647c02771c5c752b2311efd9456
├─ data::ASDF.NDArray | shape = [4159, 6353]
└─ meta::String
   ├─ aperture::String
   │  ├─ name::String | NRCA5_FULL
   │  ├─ position_angle::Float64 | 251.53592358473648
   │  └─ pps_name::String | NRCALL_FULL
   ├─ asn::String
   │  ├─ exptype::String | science
   │  ├─ pool_name::String | jw01611_20240910t150659_pool.csv
   │  └─ table_name::String | jw01611-o002_20240910t150659_image3_00001_asn.json
   ├─ background::String
  ⋮  (320) more rows
```

```julia
using CairoMakie

img_sci = let
    img = af["data"][]
    img[img .< 0] .= 1
    img
end

fig, ax, hm = heatmap(img_sci;
    colorrange = (1, 1e3),
    colorscale = log10,
    colormap = :cividis,
    nan_color = :limegreen,
)

Colorbar(fig[1, 2], hm)

fig
```

![](https://juliaastro.org/ASDF.jl/dev/examples/jwst/0de3c21f.png)

---

See [`ASDF.jl v1`](https://github.com/JuliaAstro/ASDF.jl/tree/v1) for the older version of ASDF.jl, which wraps the [`asdf`](https://github.com/spacetelescope/asdf) Python package.
