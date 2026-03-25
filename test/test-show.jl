@testset "Show method for `ASDF.ASDFFile`" begin
    af = load("blue_upchan_gain.00000000.asdf")

    @test occursin("blue_upchan_gain.00000000.asdf\n├─", sprint(show, MIME"text/plain"(), af))

    @test occursin("(5) more rows", sprint(io -> ASDF.info(io, af; max_rows = 5)))

    # I'm sure there's a better way to test this code path
    @test ASDF.info(af; max_rows = 5) == nothing
end
