compare(field1::ASDF.NDArray, field2::ASDF.NDArray) = isequal(field1[], field2[])
compare(field1, field2) = isequal(field1, field2)

function test_fields(af1, af2)
    for ((k1, v1), (k2, v2)) in zip(af1.metadata, af2.metadata)
        if occursin("asdf", k1)
            # Skip non-data entries
        else
            @test compare(v1, v2)
        end
    end
end

function roundtrip(fpath; extensions = false, validate_checksum = true)
    af = ASDF.load_file(fpath; extensions, validate_checksum)
    fpath_roundtrip = replace(fpath, ".asdf" => "_roundtrip.asdf")
    ASDF.write_file(fpath_roundtrip, af.metadata)
    af_roundtrip = ASDF.load_file(fpath_roundtrip; extensions, validate_checksum)
    return af_roundtrip, af
end

function test_references(references)
    for reference in references
        @testset "$(reference)" begin
            af_roundtrip, af = if reference == "compressed"
                    # Bug on Python side, see 03 Apr ASDF office hour discussion
                    roundtrip(joinpath("data", "asdf-1.6.0", reference * ".asdf"); validate_checksum = false)
                else
                    roundtrip(joinpath("data", "asdf-1.6.0", reference * ".asdf"))
                end
            test_fields(af_roundtrip, af)
        end
    end
end

references = [
    "anchor",
    "ascii",
    "basic",
    "complex",
    "compressed",
    "endian",
    #"exploded", See https://github.com/JuliaAstro/ASDF.jl/issues/31
    "float",
    "int",
    "scalars",
    "shared",
    #"stream", See https://github.com/JuliaAstro/ASDF.jl/issues/31
    "structured",
    "unicode_bmp",
    "unicode_spp",
]
test_references(references)
