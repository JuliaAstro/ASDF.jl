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
    @test_throws error_type(error_message) make_ndarray(; kwargs...)
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
end

@testset "getindex" begin
    opposite = ASDF.host_byteorder == ASDF.Byteorder_little ? ASDF.Byteorder_big : ASDF.Byteorder_little

    nd = make_ndarray(; byteorder = opposite)
    @test_throws "ndarray byteorder does not match system byteorder; byteorder swapping not yet implemented." begin
        nd[]
    end

    @testset "byteorder swap on source path" begin
        expected  = Int32[1, 2, 3, 4]
        disk_bytes = collect(reinterpret(UInt8, bswap.(expected)))
        lbh    = ASDF.LazyBlockHeaders()
        push!(lbh.block_headers, make_block_header(disk_bytes))
        nd = make_ndarray(; lazy_block_headers = lbh,  source = Int64(0), data = nothing, byteorder = opposite)
        @test nd[] == expected
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
