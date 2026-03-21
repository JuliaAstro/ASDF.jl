# Roman

*Adapted from [STScI Roman Notebooks](https://spacetelescope.github.io/roman_notebooks/notebooks/working_with_asdf/working_with_asdf.html).*

In this example, we show how to use ASDF.jl to load and view some simulated astronomical data created in preparation for the future ([Nancy Grace Roman Space Telescope](https://science.nasa.gov/mission/roman-space-telescope/)) mission.

!!! note "Data availability"
    Simulated data products are currently provided by STScI via [AWS S3 buckets](https://spacetelescope.github.io/roman_notebooks/notebooks/data_discovery_and_access/data_discovery_and_access.html). Note: The data product used for this example is a moderately large file (~300 MB).

## Load

```@example roman
fpath = joinpath("..", "..", "data", "roman.asdf")

if !isfile(fpath)
    @info "Downloading Roman data"
    using AWSS3, AWS
    aws_config = AWS.AWSConfig(; creds = nothing, region = "us-east-1")
    AWSConfig(nothing, "us-east-1", "json", 3)

    # This is a large file, will take some time to download
    julia> s3_get_file(
        aws_config,
        "stpubdata",
        "roman/nexus/soc_simulations/tutorial_data/r0003201001001001004_0001_wfi01_f106_cal.asdf",
        fpath
    )
end
```

```@example roman
using ASDF

af = ASDF.load_file(fpath; extensions = true, validate_checksum = false)

af.metadata["roman"]
```

## Plot

```@example roman
using CairoMakie

img = af.metadata["roman"]["data"][]

let
    fig, ax, hm = heatmap(img[begin:1000, begin:1000]; colorscale = asinh, colorrange = (0.5, 4))
    Colorbar(fig[1, 2], hm)
    fig
end
```

!!! note
    Some ASDF files produced by the Python implementation of ASDF may save a checksum in its header block computed from the original decompressed file. This will cause ASDF.jl to fail because in constrast, it computes the checksum based on the compressed (i.e., "used data"), as per the [current specification for ASDF](https://www.asdf-format.org/projects/asdf-standard/en/1.0.1/file_layout.html#block-header). To handle this potenial failure mode, we pass `validate_checksum = false` to avoid running the default checksum.
