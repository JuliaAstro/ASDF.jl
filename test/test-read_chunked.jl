@testset "Read ASDF file with chunked arrays" begin
    asdf = load(joinpath("data", "chunking.asdf"))
    println(YAML.write(asdf.metadata))

    map_tree(output, asdf.metadata)

    chunky = asdf["chunky"][]
    @test eltype(chunky) == Float16
    @test size(chunky) == (4, 4)
    @test chunky == [
        11 21 31 41
        12 22 32 42
        13 23 33 43
        14 24 34 44
    ]

    # Chunked output is not implemented; a loaded chunked array is re-saved as one contiguous block.
    mktempdir() do directory
        filename = joinpath(directory, "chunking.asdf")
        save(filename, asdf)
        @test load(filename)["chunky"][] == chunky
    end
end
