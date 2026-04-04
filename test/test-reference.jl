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

function roundtrip(fpath)
    af = ASDF.load_file(fpath; extensions = false, validate_checksum = true)
    fpath_roundtrip = replace(fpath, ".asdf" => "_roundtrip.asdf")
    ASDF.write_file(fpath_roundtrip, af.metadata)
    af_roundtrip = ASDF.load_file(fpath_roundtrip; extensions = false, validate_checksum = true)
    return af_roundtrip, af
end

function test_references(references)
    for reference in references
        @testset "$(reference)" begin
            af_roundtrip, af = roundtrip(joinpath("data", reference * ".asdf"))
            test_fields(af_roundtrip, af)
        end
    end
end

function yea()
    references = [
        "anchor",
        "ascii",
        "basic",
        "complex",
    ]

    test_references(references)
end
