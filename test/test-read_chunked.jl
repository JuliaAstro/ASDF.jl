@testset "Read ASDF file with chunked arrays" begin
    asdf = ASDF.load_file("chunking.asdf")
    println(YAML.write(asdf.metadata))

    map_tree(output, asdf.metadata)

    chunky = asdf.metadata["chunky"][]
    @test eltype(chunky) == Float16
    @test size(chunky) == (4, 4)
    @test chunky == [
        11 21 31 41
        12 22 32 42
        13 23 33 43
        14 24 34 44
    ]
end
