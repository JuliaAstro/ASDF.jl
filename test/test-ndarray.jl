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

# TODO: Can combine these into a single call in Julia v1.13
# https://github.com/JuliaLang/julia/pull/59117
function test_ndarray(error_type, error_message; kwargs...)
    @test_throws error_type begin
        make_ndarray(; kwargs...)
    end &&
    @test_throws error_message begin
        make_ndarray(; kwargs...)
    end
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
        shape = Int64[-1],
    )
    test_ndarray(
        ArgumentError,
        "`strides` must have only positive elements.";
        strides = Int64[0],
    )
end

@testset "getindex" begin
    nd = make_ndarray(;
        byteorder = ASDF.host_byteorder == ASDF.Byteorder_little ? ASDF.Byteorder_big : ASDF.Byteorder_little
    )
    @test_throws "ndarray byteorder does not match system byteorder; byteorder swapping not yet implemented." begin
        nd[]
    end

    nd = make_ndarray(; strides = Int64[5])
    @test_throws "`data` has different stride from `ndarray.strides`" begin
        nd[]
    end
end
