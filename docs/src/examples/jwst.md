# JWST

*Adapted from [ADASS 2024 workshop](https://github.com/asdf-format/asdf-adass2024/blob/main/02_working_with_asdf/Working_with_ASDF.ipynb).*

In this example, we show how to use ASDF.jl to load and view some astronomical data taken from the James Webb Space Telescope ([JWST](https://science.nasa.gov/mission/webb/)).

!!! note "Data availability"
    The sample data for this example can be [downloaded here](https://data.science.stsci.edu/redirect/Roman/Roman_Data_Workshop/ADASS2024/jwst.asdf) from the data repository of the Space Telescope Science Institute ([STScI](https://www.stsci.edu/)). Note: it is a moderately large file (~100 MB).

## Load

```@example jwst

data_dir = joinpath("..", "..", "data")
mkpath(data_dir)
fpath = joinpath(data_dir, "jwst.asdf")

if !isfile(fpath)
    using Downloads: download

    download("https://data.science.stsci.edu/redirect/Roman/Roman_Data_Workshop/ADASS2024/jwst.asdf", fpath)
end
```

```@example jwst
using ASDF

af = ASDF.load_file(fpath; extensions = true)

af.metadata
```

## Plot

```@example jwst
using CairoMakie

img_sci = let
    img = af.metadata["data"][]
    img[img .< 0] .= 1
    img
end

fig, ax, hm = heatmap(img_sci;
    colorrange = (1, 1e3),
    colorscale = log10,
    colormap = :cividis,
    nan_color = :limegreen, # NaNs are handled automatically
)

Colorbar(fig[1, 2], hm)

fig
```
