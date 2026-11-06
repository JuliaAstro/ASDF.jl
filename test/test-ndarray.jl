function make_ndarray(;
        lazy_block_headers = ASDF.LazyBlockHeaders(),
        source = nothing,
        data = Int32[5, 6, 7, 8],
        shape = isnothing(data) ? Int64[4] : Int64[length(data)],
        datatype = ASDF.Datatype_int32,
        byteorder = ASDF.host_byteorder,
        offset = Int64(0),
        strides = isnothing(data) ? Int64[4] : Int64[length(data)],
    )
    nd = ASDF.NDArray(
        lazy_block_headers,
        source,
        data,
        shape,
        datatype,
        byteorder,
        offset,
        strides,
    )
    return nd
end

function test_ndarray(error_type, error_message; kwargs...)
    return @test_throws error_type(error_message) make_ndarray(; kwargs...)
end

@testset "construction" begin
    test_ndarray(
        ArgumentError,
        "Exactly one of `source` or `data` must be provided.";
        source = Int64(1),
        data = Int32[5, 6, 7, 8],
    )
    test_ndarray(
        ArgumentError,
        "Exactly one of `source` or `data` must be provided.";
        source = nothing,
        data = nothing,
    )
    test_ndarray(
        ArgumentError,
        "`source` must be >= 0 if provided.";
        source = Int64(-1),
        data = nothing,
    )
    test_ndarray(
        ArgumentError,
        "`data` must contain elements of type given by `datatype`.";
        data = Float64[5, 6, 7, 8],
    )
    test_ndarray(
        ArgumentError,
        "`shape` does not correctly describe the shape of `data`.";
        data = Int32[5, 6, 7, 8],
        shape = Int64[5],
    )
    test_ndarray(
        ArgumentError,
        "`offset` must be >= 0.";
        offset = Int64(-1),
    )
    test_ndarray(
        DimensionMismatch,
        "`shape` and `strides` must have the same length.";
        shape = Int64[4],
        strides = Int64[4, 5],
    )
    test_ndarray(
        ArgumentError,
        "`shape` cannot have negative elements.";
        source = Int64(0),
        data = nothing,
        shape = Int64[-1],
    )
    test_ndarray(
        ArgumentError,
        "`strides` must have only positive elements.";
        strides = Int64[0],
    )
    test_ndarray(
        ArgumentError,
        "Unknown string datatype kind: utf16";
        datatype = ["utf16", 8],
    )
end

@testset "implicit strides with zero-length dimensions" begin
    # 2026/08/06: Regression test for STScI Roman L2 `.asdf` products produced by romanisim,
    # which contain `!core/ndarray` nodes (e.g. `chisq`/`dumo`) with a zero-length shape and
    # no explicit `strides` key; see the default-strides comment in the `NDArray` outer
    # constructor for the NumPy convention involved. Expected values below were verified
    # against `np.ndarray(shape, dtype, buffer, offset, strides=None, order='C').strides`.
    cases = [
        (Int64[0, 0], ASDF.Datatype_float16, Int64[2, 2]),
        (Int64[0, 5], ASDF.Datatype_float32, Int64[20, 4]),
        (Int64[5, 0], ASDF.Datatype_float32, Int64[4, 4]),
        (Int64[0, 0, 3], ASDF.Datatype_float32, Int64[12, 12, 4]),
        (Int64[2, 0, 3], ASDF.Datatype_float32, Int64[12, 12, 4]),
        (Int64[0, 2, 3], ASDF.Datatype_float32, Int64[24, 12, 4]),
    ]
    for (shape, datatype, expected_strides) in cases
        lbh = ASDF.LazyBlockHeaders()
        push!(lbh.block_headers, make_block_header(UInt8[]))
        nd = make_ndarray(;
            lazy_block_headers = lbh, source = Int64(0), data = nothing, shape, datatype, strides = nothing,
        )
        @test nd.strides == expected_strides
        # Materialize from an empty block to catch stride-check false positives at read time.
        arr = nd[]
        @test size(arr) == Tuple(reverse(shape))
        @test eltype(arr) == Type(datatype)
    end
end

@testset "implicit strides with negative-shape elements" begin
    # Regression test: the implicit-strides branch of
    # the `NDArray` outer constructor clamps negative entries so the
    # `strides` positivity check downstream can't misfire on them. That clamping only affects
    # the temporary array used to compute `strides`; it must not suppress the `shape`
    # negativity check in the inner constructor, which always receives the original,
    # unclamped `shape`. Cover a negative element both outside (`shape[1]`) and inside
    # (`shape[2:end]`) the slice passed to `max.(...)`.
    for shape in (Int64[-1, 3], Int64[3, -1])
        test_ndarray(
            ArgumentError,
            "`shape` cannot have negative elements.";
            source = Int64(0),
            data = nothing,
            shape,
            strides = nothing,
        )
    end
end

@testset "getindex" begin
    opposite = ASDF.host_byteorder == ASDF.Byteorder_little ? ASDF.Byteorder_big : ASDF.Byteorder_little

    nd = make_ndarray(; byteorder = opposite)
    @test_throws "ndarray byteorder does not match system byteorder; byteorder swapping not yet implemented." begin
        nd[]
    end

    @testset "byteorder swap on source path" begin
        expected = Int32[1, 2, 3, 4]
        disk_bytes = collect(reinterpret(UInt8, bswap.(expected)))
        lbh = ASDF.LazyBlockHeaders()
        push!(lbh.block_headers, make_block_header(disk_bytes))

        nd = make_ndarray(; lazy_block_headers = lbh, source = Int64(0), data = nothing, byteorder = opposite)
        @test nd[] == expected

        nd = make_ndarray(; lazy_block_headers = lbh, source = Int64(0), data = nothing, byteorder = opposite, datatype = ASDF.Ucs4Datatype(2), shape = [Int64(1)], strides = [Int64(8)])
        # ucs4 data is presented as a string-like `UCS4String`, byte-swapped to host order
        @test eltype(nd[]) <: AbstractString
        @test nd[] == [join((Char(0x01), Char(0x02)))]
    end

    nd = make_ndarray(; strides = Int64[5])
    @test_throws "`data` has different stride from `ndarray.strides`" begin
        nd[]
    end
end

@testset "ndarray chunk" begin
    nd = make_ndarray()

    @test begin
        ndc = ASDF.NDArrayChunk(0:0, make_ndarray())
        ndc.start == [0]
    end

    @test_throws "start` and `strides` have a different number of elements" begin
        ASDF.NDArrayChunk(Int64[1, 2], nd)
    end

    @test_throws "`start` cannot contain negative values" begin
        ASDF.NDArrayChunk(Int64[-1], nd)
    end
end

@testset "chunked ndarray" begin
    @test_throws "`shape` cannot contain negative values" begin
        ASDF.ChunkedNDArray(Int64[-1], ASDF.Datatype_int32, ASDF.NDArrayChunk[])
    end

    nd = make_ndarray()

    @test_throws "Different number of dimensions specified by `chunks` and `shape`" begin
        chunk = ASDF.NDArrayChunk(Int64[0], nd)
        ASDF.ChunkedNDArray(Int64[], ASDF.Datatype_int32, [chunk])
    end

    @test_throws "`chunk.start` exceeds number of elements in dimension" begin
        chunk = ASDF.NDArrayChunk(Int64[5], nd)
        ASDF.ChunkedNDArray(Int64[2], ASDF.Datatype_int32, [chunk])
    end

    @test_throws "`chunk` exceeds number of elements as specified by `shape`" begin
        chunk = ASDF.NDArrayChunk(Int64[0], nd)
        ASDF.ChunkedNDArray(Int64[1], ASDF.Datatype_int32, [chunk])
    end

    @test_throws "`datatype` and type of `chunk` cannot be different" begin
        chunk = ASDF.NDArrayChunk(Int64[0], nd)
        ASDF.ChunkedNDArray(Int64[6], ASDF.Datatype_int8, [chunk])
    end
end

@testset "inline data of any dimension" begin
    # Inline `data` nests one list per dimension with the first `shape` dimension outermost, as
    # Python `asdf` writes it; the result has size `reverse(shape)`. `stack` used to reject empty
    # data and could not build arrays of more than two dimensions.
    inline(data, shape) = ASDF.NDArray(ASDF.LazyBlockHeaders(), nothing, data, shape, "float64", nothing, nothing, nothing)[]
    @test inline([1.5, 2.5], [2]) == [1.5, 2.5]
    @test inline([[0.0, 1.0, 2.0], [3.0, 4.0, 5.0]], [2, 3]) == [0.0 3.0; 1.0 4.0; 2.0 5.0]
    nested = [[[12.0 * i + 4.0 * j + k for k in 0:3] for j in 0:2] for i in 0:1]
    array = inline(nested, [2, 3, 4])
    @test array == reshape(collect(0.0:23.0), 4, 3, 2)
    @test eltype(array) == Float64
    for (data, shape) in (([], [0]), ([], [0, 3]), ([[], [], []], [3, 0]))
        empty = inline(data, shape)
        @test size(empty) == Tuple(reverse(shape))
        @test eltype(empty) == Float64
    end
    # Julia arrays of other dimensions, such as the data of a loaded inline ndarray, are already in Julia order.
    @test inline([0.0 1.0; 2.0 3.0], [2, 2]) == [0.0 1.0; 2.0 3.0]
    # Python `asdf` rejects data that does not match `shape`, including data nested too shallowly
    # whose element count matches, or nested too deeply.
    for (data, shape) in (
            ([[1.0, 2.0], [3.0, 4.0]], [2, 2, 1]), ([[1.0, 2.0], [3.0]], [2, 2]), ([[1.0, 2.0], [3.0, 4.0]], [2, 3]), ([1.0, 2.0], [3]),
            ([[1.0], [2.0]], [2]), ([1.5], Int64[]), (zeros(2, 3), [2, 3]),
        )
        @test_throws ArgumentError("`shape` does not correctly describe the shape of `data`.") inline(data, shape)
    end
end

@testset "read inline arrays of any dimension" begin
    # The layout Python `asdf` writes for `set_array_storage(array, "inline")`.
    path = joinpath(mktempdir(; cleanup = true), "inline.asdf")
    text = """
    #ASDF 1.0.0
    #ASDF_STANDARD 1.6.0
    %YAML 1.1
    %TAG ! tag:stsci.edu:asdf/
    --- !core/asdf-1.1.0
    cube: !core/ndarray-1.1.0
      data:
      - - [0, 1, 2, 3]
        - [4, 5, 6, 7]
        - [8, 9, 10, 11]
      - - [12, 13, 14, 15]
        - [16, 17, 18, 19]
        - [20, 21, 22, 23]
      datatype: int16
      shape: [2, 3, 4]
    empty: !core/ndarray-1.1.0
      data: []
      datatype: float64
      shape: [0, 3]
    ...
    """
    write(path, text)
    file = ASDF.load_file(path)
    cube = file["cube"][]
    @test cube == reshape(Int16.(0:23), 4, 3, 2)
    @test eltype(cube) == Int16
    @test size(file["empty"][]) == (3, 0)
end

@testset "0-dimensional arrays" begin
    # `data/zero_dimensional.asdf` was written by Python `asdf` 5.3.1:
    # asdf.AsdfFile({"float64": np.array(1.5), "int16_big": np.array(-7, dtype=">i2"), "bool": np.array(True)}).write_to(...)
    # YAML reads its `shape: []` as a `Vector{Any}`, and a 0-dimensional array has no strides.
    file = load(joinpath("data", "zero_dimensional.asdf"))
    for (key, value) in (("float64", 1.5), ("int16_big", Int16(-7)), ("bool", true))
        @test file[key].shape == Int64[]
        @test file[key].strides == Int64[]
        array = file[key][]
        @test size(array) == ()
        @test eltype(array) == typeof(value)
        @test array[] == value
    end
    # A file read from Python can be written back out.
    path = joinpath(mktempdir(; cleanup = true), "rewritten.asdf")
    ASDF.write_file(path, Dict{Any, Any}(key => file[key] for key in ("float64", "int16_big", "bool")))
    rewritten = load(path)
    for key in ("float64", "int16_big", "bool")
        @test rewritten[key][] == file[key][]
        @test eltype(rewritten[key][]) == eltype(file[key][])
    end
end

@testset "block-backed arrays stay inside their block" begin
    # `StridedView` reads the block with `@inbounds`, so the `offset`, `shape`, and `strides` of a corrupt or crafted file
    # are checked against the block length first. Reading past it returned heap memory or crashed.
    path = joinpath(mktempdir(; cleanup = true), "bounds.asdf")
    ASDF.write_file(path, Dict{Any, Any}("a" => ASDF.NDArrayWrapper([1.0, 2.0, 3.0]; compression = ASDF.C_None)))
    nd = ASDF.load_file(path)["a"]
    read_as(offset, shape, strides) = ASDF.NDArray(nd.lazy_block_headers, nd.source, nothing, shape, nd.datatype, nd.byteorder, offset, strides)[]
    @test read_as(8, [2], [8]) == [2.0, 3.0] # ends exactly at the end of the 24-byte block
    @test read_as(0, [2], [16]) == [1.0, 3.0]
    @test read_as(16, Int64[], Int64[]) == fill(3.0)
    @test size(read_as(1000, [0], [8])) == (0,) # an empty array reads nothing
    # The last case overflows `Int64`, which would wrap around to a negative byte count.
    for (offset, shape, strides) in ((16, [2], [8]), (4096, [3], [8]), (0, [100000], [8]), (2^40, Int64[], Int64[]), (0, [3], [2^62]))
        @test_throws "-byte block" read_as(offset, shape, strides)
    end
end

# Load a file whose tree is `tree`.
function load_tree(tree)
    path = joinpath(mktempdir(; cleanup = true), "tree.asdf")
    write(path, "#ASDF 1.0.0\n#ASDF_STANDARD 1.6.0\n%YAML 1.1\n%TAG ! tag:stsci.edu:asdf/\n--- !core/asdf-1.1.0\n" * tree * "...\n")
    return ASDF.load_file(path)
end

@testset "inline data with inferred shape and datatype" begin
    # Inline data may leave out `shape` and `datatype`, and the whole tag may be the nested list.
    # The first two are the ndarray schema's own examples; the rest follow its inference rules.
    file = load_tree(
        """
        implicit: !core/ndarray-1.1.0
          [[1, 0, 0],
           [0, 1, 0],
           [0, 0, 1]]
        explicit: !core/ndarray-1.1.0
          datatype: float64
          data:
            [[1, 0, 0],
             [0, 1, 0],
             [0, 0, 1]]
        rows: !core/ndarray-1.1.0 [[1, 2, 3], [4, 5, 6]]
        floats: !core/ndarray-1.1.0 [1, 2.5]
        bools: !core/ndarray-1.1.0 [true, false]
        empty: !core/ndarray-1.1.0 []
        complex: !core/ndarray-1.1.0 [!core/complex-1.0.0 (1+2j), !core/complex-1.0.0 3-4J, 5]
        strings: !core/ndarray-1.1.0 [abc, de]
        """
    )
    for (key, expected) in (
            "implicit" => [1 0 0; 0 1 0; 0 0 1],
            "explicit" => [1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0],
            "rows" => [1 4; 2 5; 3 6],
            "floats" => [1.0, 2.5],
            "bools" => [true, false],
            "empty" => Float64[],
            "complex" => ComplexF64[1 + 2im, 3 - 4im, 5],
        )
        @test file[key][] == expected
        @test eltype(file[key][]) == eltype(expected)
    end
    # Strings infer `ucs4` as wide as the longest one.
    @test file["strings"][] == ["abc", "de"]
    @test eltype(file["strings"][]) == ASDF.UCS4String{3}
end

@testset "inline strings, complex values and nulls" begin
    # `ascii` and `ucs4` elements are YAML strings, null-padded to the datatype's length.
    file = load_tree(
        """
        ascii: !core/ndarray-1.1.0 {data: [abc, de], datatype: [ascii, 3]}
        ucs4: !core/ndarray-1.1.0 {data: [abc, é], datatype: [ucs4, 3]}
        complex64: !core/ndarray-1.1.0 {data: [!core/complex-1.0.0 1i, 2], datatype: complex64}
        """
    )
    @test file["ascii"][] == ["abc", "de"]
    @test eltype(file["ascii"][]) == ASDF.AsciiString{3}
    @test file["ucs4"][] == ["abc", "é"]
    @test file["complex64"][] == ComplexF32[1im, 2]
    @test eltype(file["complex64"][]) == ComplexF32
    for (tree, message) in (
            ("a: !core/ndarray-1.1.0 {data: [abcd], datatype: [ascii, 3]}\n", "is longer than the 3 characters"),
            ("a: !core/ndarray-1.1.0 {data: [é], datatype: [ascii, 3]}\n", "is not ASCII"),
            # Masked values are not supported yet; see asdf-format/asdf-standard#451 and #452.
            ("a: !core/ndarray-1.1.0 {data: [1.0, null], datatype: float64}\n", "not supported yet"),
            ("a: !core/ndarray-1.1.0 {source: 0, datatype: float64, byteorder: little}\n", "needs `shape` and `datatype`"),
        )
        @test_throws message load_tree(tree)
    end
end

@testset "complex scalars" begin
    # `!core/complex-1.0.0` values read as `ComplexF64`, in every form its schema allows, and are
    # written back with the same tag.
    file = load_tree("values: [!core/complex-1.0.0 1-1j, !core/complex-1.0.0 1J, !core/complex-1.0.0 -1, !core/complex-1.0.0 (1.5e-3+2e+2I), !core/complex-1.0.0 inf-nanj]\n")
    values = ComplexF64[1 - 1im, 1im, -1, 0.0015 + 200im, complex(Inf, NaN)]
    @test isequal(file["values"], values)
    path = joinpath(mktempdir(; cleanup = true), "complex.asdf")
    ASDF.write_file(path, file.metadata)
    @test occursin("!core/complex-1.0.0 \"1.0-1.0i\"", read(path, String))
    @test isequal(ASDF.load_file(path)["values"], values)
end
