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
            "element4" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Lz4, lz4_layout=:block),
            "element5" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Lz4, lz4_layout=:frame),
            "element6" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Xz),
            "element7" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Zlib),
            "element8" => ASDF.NDArrayWrapper(array; compression=ASDF.C_Zstd),
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

    for n in 1:8
        element = doc["group"]["element$n"][]
        element′ = doc′.metadata["group"]["element$n"][]
        @test eltype(element′) == eltype(element)
        @test size(element′) == size(element)
        @test element′ == element
    end

    @test_throws "`array` has invalid state: `compression` field has value not specified in `Compression` enum." begin
        doc = Dict{Any, Any}("field1" => ASDF.NDArrayWrapper([5, 6, 7, 8]; compression = ASDF.C_Blosc2))
        ASDF.write_file(filename, doc)
    end
end

@testset "Write `ASDFFile`" begin
    file = ASDF.ASDFFile("my_file.asdf", Dict{Any, Any}("x" => 1), ASDF.LazyBlockHeaders())
    result = YAML.write(file)
    @test result == "[ASDF file \"my_file.asdf\"]\nx: 1\n"
end

@testset "helper functions" begin
    @test ASDF.native2big_U8(0x05) == [0x05]
    @test ASDF.native2big_U8(5) == [0x05]
end
