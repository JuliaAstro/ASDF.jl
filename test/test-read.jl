@testset "Read ASDF file" begin
    asdf = ASDF.load_file("blue_upchan_gain.00000000.asdf")
    println(YAML.write(asdf.metadata))

    map_tree(output, asdf.metadata)

    buffer = asdf.metadata[0]["buffer"][]
    @test eltype(buffer) == Float16
    @test size(buffer) == (256,)
    @test buffer == fill(1, 256)

    dish_index = asdf.metadata[0]["dish_index"][]
    @test eltype(dish_index) == Int32
    @test size(dish_index) == (3, 2)
    @test dish_index == [
        -1 -1
        42 53
        43 54
    ]
end
