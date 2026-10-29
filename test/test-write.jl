@testset "Write ASDF file" begin
    dirname = mktempdir(; cleanup = true)
    filename = joinpath(dirname, "output.asdf")

    array = Float64[1 / (i + j + k - 2) for i in 1:50, j in 1:51, k in 1:52]
    doc = Dict(
        "data1" => ASDF.NDArrayWrapper([1 2; 3 4]; inline = false),
        "data2" => ASDF.NDArrayWrapper([1 2; 3 4]; inline = true),
        "group" => Dict(
            "element1" => ASDF.NDArrayWrapper(array; compression = ASDF.C_None),
            "element2" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Blosc),
            "element3" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Bzip2),
            "element4" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Lz4, lz4_layout = :block),
            "element5" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Lz4, lz4_layout = :frame),
            "element6" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Xz),
            "element7" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Zlib),
            "element8" => ASDF.NDArrayWrapper(array; compression = ASDF.C_Zstd),
        ),
    )
    save(filename, doc)

    doc′ = load(filename)
    map_tree(output, doc′.metadata)

    data1 = doc["data1"][]
    data1′ = doc′["data1"][]
    @test eltype(data1′) == eltype(data1)
    @test size(data1′) == size(data1)
    @test data1′ == data1

    data2 = doc["data2"][]
    data2′ = doc′["data2"][]
    @test eltype(data2′) == eltype(data2)
    @test size(data2′) == size(data2)
    @test data2′ == data2

    for n in 1:8
        element = doc["group"]["element$n"][]
        element′ = doc′["group"]["element$n"][]
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

@testset "Mutate and re-save an `ASDFFile`" begin
    dir = mktempdir(; cleanup = true)
    orig = joinpath(dir, "orig.asdf")
    resaved = joinpath(dir, "resaved.asdf")

    save(orig, Dict{Any, Any}("x" => 1))
    af = load(orig)
    af["x"] = 2
    af["y"] = "new"
    @test af["x"] == 2

    # `save` accepts the `ASDFFile` wrapper itself, unwrapping to its metadata tree.
    save(resaved, af)
    af′ = load(resaved)
    @test af′["x"] == 2
    @test af′["y"] == "new"
end

@testset "helper functions" begin
    @test ASDF.native2big_U8(0x05) == [0x05]
    @test ASDF.native2big_U8(5) == [0x05]
end

@testset "floats use YAML-1.1-compliant exponents" begin
    # YAML 1.1 only reads an exponent as a float when it has an explicit sign, so the writer must
    # emit `2.998e+8`, not Julia's `2.998e8` (which strict parsers, e.g. the Python `asdf`, read
    # back as a *string*). The fix must not cost precision or touch already-signed exponents.
    @test ASDF.yaml_float_string(2.998e8) == "2.998e+8"
    @test ASDF.yaml_float_string(6.022e23) == "6.022e+23"
    @test ASDF.yaml_float_string(-5.204446308234682e7) == "-5.204446308234682e+7"
    @test ASDF.yaml_float_string(1.5e-7) == "1.5e-7"
    @test ASDF.yaml_float_string(1.0) == "1.0"
    @test ASDF.yaml_float_string(Float32(5.2e7)) == "5.2e+7"
    @test ASDF.yaml_float_string(NaN) == ".NaN"
    @test ASDF.yaml_float_string(Inf) == ".inf"
    @test ASDF.yaml_float_string(-Inf) == "-.inf"

    # End-to-end: the value is written with a signed exponent and reloads as an exact `Float64`
    # (not a string), which is what makes the file valid for the Python `asdf` reader.
    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "sci.asdf")
    value = -5.204446308234682e7
    ASDF.write_file(path, Dict{Any, Any}("spatial_x" => value))
    @test occursin("spatial_x: -5.204446308234682e+7", read(path, String))

    reloaded = ASDF.load_file(path)["spatial_x"]
    @test reloaded isa Float64
    @test reloaded == value

    # Inline ndarray data must get the same treatment: its element text is produced by
    # `NDArrayWrapper`'s own writer, which routes the slices back through the float pass.
    arr = [2.998e8 6.022e23]
    ipath = joinpath(dir, "inline.asdf")
    ASDF.write_file(ipath, Dict{Any, Any}("inline_arr" => ASDF.NDArrayWrapper(arr; inline = true)))
    itext = read(ipath, String)
    @test occursin("2.998e+8", itext)
    @test occursin("6.022e+23", itext)
    @test !occursin("2.998e8", itext)
    @test ASDF.load_file(ipath)["inline_arr"][] == arr
end

@testset "write preserves key order for non-OrderedDict documents" begin
    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "order.asdf")

    # A `TaggedMapping` top-level document is an `AbstractDict` that is *not* an `OrderedDict`.
    # The old `merge(document, ...)` degraded such inputs to an unordered `Dict`, scrambling key
    # order; `write_file` now rebuilds an `OrderedDict` so insertion order is preserved. Use a
    # deliberately non-alphabetical order so hash ordering would not match by coincidence.
    doc = ASDF.TaggedMapping(
        "tag:example.org:mylib/root-1.0.0",
        OrderedDict{Any, Any}("zebra" => 1, "apple" => 2, "mango" => 3),
    )

    ASDF.write_file(path, doc)
    reloaded = ASDF.load_file(path)

    # User keys keep their insertion order; the auto-inserted provenance entry comes last.
    @test collect(keys(reloaded.metadata)) == ["zebra", "apple", "mango", "asdf_library"]
end

@testset "write inline arrays of any dimension" begin
    # Inline `data` must nest one list per dimension. Splitting with `eachslice` gave the right
    # nesting only for matrices: vectors and empty arrays were written as `fill(...)` and arrays of
    # more than two dimensions as a matrix of vectors, neither valid YAML ndarray data.
    path = joinpath(mktempdir(; cleanup = true), "inline.asdf")
    arrays = Dict{Any, Any}(
        "vector" => [1.5, 2.5],
        "matrix" => Int16[1 2 3; 4 5 6],
        "cube" => reshape(collect(1.0:24.0), 2, 3, 4),
        "bool" => [true, false, true],
        "empty" => Float64[],
        "empty_rows" => zeros(Float32, 0, 3),
        "empty_columns" => zeros(Float32, 3, 0),
    )
    ASDF.write_file(path, Dict{Any, Any}(key => ASDF.NDArrayWrapper(array; inline = true) for (key, array) in arrays))
    text = read(path, String)
    @test !occursin("fill(", text)
    @test !occursin("YAMLScalar", text)
    file = ASDF.load_file(path)
    for (key, array) in arrays
        array′ = file[key][]
        @test eltype(array′) == eltype(array)
        @test size(array′) == size(array)
        @test array′ == array
    end
    @test file["cube"].shape == [4, 3, 2]
end

@testset "write 0-dimensional arrays" begin
    # The shape of a 0-dimensional array is empty, which `collect(reverse(size(array)))` gave as a `Vector{Any}`.
    path = joinpath(mktempdir(; cleanup = true), "zero_dimensional.asdf")
    arrays = Dict{Any, Any}(
        "none" => (fill(1.5), ASDF.C_None),
        "zlib" => (fill(Int16(-7)), ASDF.C_Zlib),
        "bzp2" => (fill(true), ASDF.C_Bzip2),
        "lz4" => (fill(2.5f0), ASDF.C_Lz4),
    )
    ASDF.write_file(path, Dict{Any, Any}(key => ASDF.NDArrayWrapper(array; compression) for (key, (array, compression)) in arrays))
    @test occursin("shape: []", read(path, String))
    file = ASDF.load_file(path)
    for (key, (array, _)) in arrays
        array′ = file[key][]
        @test size(array′) == ()
        @test eltype(array′) == eltype(array)
        @test array′[] == array[]
    end
    # The ndarray schema requires inline data to be a list, so a 0-dimensional array has no inline form.
    @test_throws ArgumentError("a 0-dimensional array cannot be stored inline; use `inline = false`") ASDF.write_file(path, Dict{Any, Any}("a" => ASDF.NDArrayWrapper(fill(1.5); inline = true)))
end
