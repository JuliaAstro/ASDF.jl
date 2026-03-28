@testset "" begin
    nd = ASDF.NDArray(
        ASDF.LazyBlockHeaders(), # lazy_block_headers
        nothing, # source
        Int32[5, 6, 7, 8], # data
        Int64[4], # shape
        ASDF.Datatype_int32, # datatype
        ASDF.host_byteorder == ASDF.Byteorder_little ? ASDF.Byteorder_big : ASDF.Byteorder_little, # byteorder
        Int64(0), # offset
        Int64[5], # strides
    )

    @test_throws "ndarray byteorder does not match system byteorder; byteorder swapping not yet implemented." begin
        nd[]
    end
end
