@testset "Show method for `ASDF.ASDFFile`" begin
    af = load("blue_upchan_gain.00000000.asdf")

    sprint(show, MIME"text/plain"(), af) == """
    test/blue_upchan_gain.00000000.asdf
    ├─ 0::Int64
    │  ├─ buffer::ASDF.NDArray | shape = [256]
    │  ├─ dim_names::Vector{String} | shape = (1,)
    │  └─ dish_index::ASDF.NDArray | shape = [2, 3]
    └─ asdf/library::String
       ├─ author::String | Erik Schnetter
       ├─ homepage::String | https://github.com/eschnett/asdf-cxx
       ├─ name::String | asdf-cxx
       └─ version::String | 7.2.0
    """
end
