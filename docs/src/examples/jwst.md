# JWST

*Adapted from [ADASS 2024 workshop](https://github.com/asdf-format/asdf-adass2024/blob/main/02_working_with_asdf/Working_with_ASDF.ipynb).*

## Reading an ASDF file

```@example jwst
using ASDF

af = ASDF.load_file("../../data/jwst.asdf")

af.metadata
```

```@example jwst
img_sci = let
    img = af.metadata["data"][]
    img[img .< 0] .= 1
    img
end
```

And plot:

```@example jwst
using CairoMakie

fig, ax, hm = heatmap(img_sci;
    colorrange = (1, 1e3),
    colorscale = log10,
    colormap = :cividis,
    nan_color = :lime, # NaNs are handled automatically
)

Colorbar(fig[1, 2], hm)

fig
```
