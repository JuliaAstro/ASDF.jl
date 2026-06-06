@testset "Read ASDF file" begin
    asdf = load(joinpath("data", "blue_upchan_gain.00000000.asdf"))
    println(YAML.write(asdf.metadata))

    map_tree(output, asdf.metadata)

    buffer = asdf[0]["buffer"][]
    @test eltype(buffer) == Float16
    @test size(buffer) == (256,)
    @test buffer == fill(1, 256)

    dish_index = asdf[0]["dish_index"][]
    @test eltype(dish_index) == Int32
    @test size(dish_index) == (3, 2)
    @test dish_index == [
        -1 -1
        42 53
        43 54
    ]
end

@testset "find_first_block" begin
    io = IOBuffer([zeros(UInt8, 10); ASDF.block_magic_token; zeros(UInt8, 50)])
    @test ASDF.find_first_block(io) == Int64(10)
end

@testset "find_first_block with token beyond first 10 MB buffer" begin
    preamble = zeros(UInt8, 10_000_000)
    io = IOBuffer([preamble; ASDF.block_magic_token; zeros(UInt8, 50)])
    @test ASDF.find_first_block(io) == Int64(10_000_000)
end

@testset "helper functions" begin
    @test ASDF.big2native_U8(UInt8[5, 6, 7]) == 0x05
end
