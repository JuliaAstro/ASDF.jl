using ParallelTestRunner: runtests, find_tests, parse_args
using ASDF

const init_code = quote
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
end

args = parse_args(Base.ARGS)
testsuite = find_tests(@__DIR__)

runtests(ASDF, args; testsuite, init_code)
