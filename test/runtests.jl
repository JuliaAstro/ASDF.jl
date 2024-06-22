using ASDF2
using Test
using YAML

map_tree(f, x) = f(x)
map_tree(f, vec::AbstractVector) = [map_tree(f, elem) for elem in vec]
map_tree(f, dict::AbstractDict) = Dict(key => map_tree(f, val) for (key, val) in dict)

output(x) = nothing
function output(arr::ASDF2.NDArray)
    println("source: $(arr.source)")
    data = arr[]
    println("    type: $(typeof(data))")
    return println("    size: $(size(data))")
end

################################################################################

asdf = ASDF2.load_file("blue_upchan_gain.00000000.asdf")
println(YAML.write(asdf.metadata))

map_tree(output, asdf.metadata)

buffer = asdf.metadata[0]["buffer"][]
@test eltype(buffer) == Float16
@test size(buffer) == (256,)
@test buffer == fill(1, 256)

dish_index = asdf.metadata[0]["dish_index"][]
@test eltype(dish_index) == Int32
@test size(dish_index) == (3, 2)
@test dish_index == [
    -1 -1
    42 53
    43 54
]

################################################################################

asdf = ASDF2.load_file("chunking.asdf")
println(YAML.write(asdf.metadata))

map_tree(output, asdf.metadata)

chunky = asdf.metadata["chunky"][]
@test eltype(chunky) == Float16
@test size(chunky) == (4, 4)
@test chunky == [
    11 21 31 41
    12 22 32 42
    13 23 33 43
    14 24 34 44
]
