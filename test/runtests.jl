using ASDF2
using Test
using YAML

# asdf = ASDF2.load_file("/tmp/blue_voltage.00000000.asdf")
asdf = ASDF2.load_file("/tmp/blue_upchan_gain.00000000.asdf")
println(YAML.write(asdf.metadata))

map_tree(f, x) = f(x)
map_tree(f, vec::AbstractVector) = [map_tree(f, elem) for elem in vec]
map_tree(f, dict::AbstractDict) = Dict(key => map_tree(f, val) for (key, val) in dict)

map_tree(asdf.metadata) do x
    if x isa ASDF2.NDArray
        println("source: $(x.source)")
        data = x[]
        println("    type: $(typeof(data))")
        println("    size: $(size(data))")
    end
end
