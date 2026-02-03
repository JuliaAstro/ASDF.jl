using ASDF
using Test
using YAML

map_tree(f, x) = f(x)
map_tree(f, vec::AbstractVector) = [map_tree(f, elem) for elem in vec]
map_tree(f, dict::AbstractDict) = Dict(key => map_tree(f, val) for (key, val) in dict)

output(x) = nothing
function output(arr::ASDF.NDArray)
    println("source: $(arr.source)")
    data = arr[]
    println("    type: $(typeof(data))")
    return println("    size: $(size(data))")
end

################################################################################

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

################################################################################

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

################################################################################

@testset "Write ASDF file" begin
    dirname = mktempdir(; cleanup=true)
    filename = joinpath(dirname, "output.asdf")

    array = Float64[1/(i+j+k-2) for i in 1:50, j in 1:51, k in 1:52]
    doc = Dict{Any,Any}(
        "data1" => ASDF.NDArrayWrapper([1 2; 3 4]; inline=false),
        "data2" => ASDF.NDArrayWrapper([1 2; 3 4]; inline=true),
        "group" => Dict{Any,Any}(
            "element1" => ASDF.NDArrayWrapper(array; compression=ASDF.C_None),
            "element2" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Blosc),
            "element3" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Bzip2),
            "element4" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Lz4),
            "element5" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Xz),
            "element6" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Zlib),
            "element7" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Zstd),
        ),
    )
    ASDF.write_file(filename, doc)

    doc′ = ASDF.load_file(filename)
    map_tree(output, doc′.metadata)

    data1 = doc["data1"][]
    data1′ = doc′.metadata["data1"][]
    @test eltype(data1′) == eltype(data1)
    @test size(data1′) == size(data1)
    @test data1′ == data1

    data2 = doc["data2"][]
    data2′ = doc′.metadata["data2"][]
    @test eltype(data2′) == eltype(data2)
    @test size(data2′) == size(data2)
    @test data2′ == data2

    for n in 1:7
        element = doc["group"]["element$n"][]
        element′ = doc′.metadata["group"]["element$n"][]
        @test eltype(element′) == eltype(element)
        @test size(element′) == size(element)
        @test element′ == element
    end
end
