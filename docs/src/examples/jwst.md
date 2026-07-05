# JWST

*Adapted from [ADASS 2024 workshop](https://github.com/asdf-format/asdf-adass2024/blob/main/02_working_with_asdf/Working_with_ASDF.ipynb).*

In this example, we show how to use ASDF.jl to load and view some astronomical data taken from the James Webb Space Telescope ([JWST](https://science.nasa.gov/mission/webb/)).

!!! note "Data availability"
    The sample data for this example can be [downloaded here](https://data.science.stsci.edu/redirect/Roman/Roman_Data_Workshop/ADASS2024/jwst.asdf) from the data repository of the Space Telescope Science Institute ([STScI](https://www.stsci.edu/)). Note: it is a moderately large file (~100 MB).

## Load

```@example jwst
using ASDF, Downloads

fpath = let
    filename = joinpath(mkpath(pkgdir(ASDF, "data")), "jwst.asdf")
    url = "https://data.science.stsci.edu/redirect/Roman/Roman_Data_Workshop/ADASS2024/jwst.asdf"
    isfile(filename) || Downloads.download(url, filename)
    filename
end

af = load(fpath; extensions = true)
```

## Plot

```@example jwst
using CairoMakie

img_sci = let
    img = af["data"][]
    img[img .< 0] .= 1
    img
end

telescope = af["meta"]["telescope"]
instr     = af["meta"]["instrument"]["name"]
filt      = af["meta"]["instrument"]["filter"]

fig, ax, hm = heatmap(img_sci;
    axis = (;
        xlabel = "X",
        ylabel = "Y",
        title = "$(telescope) $(instr) -- $(filt)",
    ),
    colorrange = (1, 1e3),
    colorscale = log10,
    colormap = :cividis,
    nan_color = :coral,
)

Colorbar(fig[1, 2], hm; label = "Counts")

fig
```

!!! note
    By default, Makie.jl places the origin in the lower left corner and transposes the data, matching the convention used in the Python workshop example. To have the plot orientation match the data orientation instead, modify the above plot command to: `heatmap(arr'; axis = (; yreversed = true))`. See also [`permutedims`](https://docs.julialang.org/en/v1/base/arrays/#Base.permutedims) for a more general alternative to the adjoint (conjugate transpose) operation: [`'`](https://docs.julialang.org/en/v1/stdlib/LinearAlgebra/#Base.adjoint).
