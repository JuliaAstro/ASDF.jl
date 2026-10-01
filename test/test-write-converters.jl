using Dates: Date, DateTime

struct WriteValue
    value::Int
end
struct WriteParent
    child
end
struct WriteAlias
    value::WriteValue
end
struct WriteBlock
    data::Matrix{Float64}
end
struct WriteLoop end
mutable struct WriteSame
    value::Int
end
struct WriteMapping <: AbstractDict{String, Any}
    entries::OrderedDict{String, Any}
end
Base.iterate(m::WriteMapping, state...) = iterate(m.entries, state...)
Base.length(m::WriteMapping) = length(m.entries)
Base.getindex(m::WriteMapping, key) = m.entries[key]
struct UnsupportedWriteValue end

ASDF.to_tree(value::WriteValue) = ASDF.TaggedMapping("tag:example.org/write/value-1.0.0", OrderedDict("value" => value.value))
ASDF.to_tree(value::WriteParent) = ASDF.TaggedMapping("tag:example.org/write/parent-1.0.0", OrderedDict("child" => value.child))
ASDF.to_tree(value::WriteAlias) = value.value
ASDF.to_tree(value::WriteBlock) = ASDF.TaggedMapping("tag:example.org/write/block-1.0.0", OrderedDict("data" => ASDF.NDArrayWrapper(value.data; compression = ASDF.C_Zlib)))
ASDF.to_tree(value::WriteLoop) = OrderedDict("self" => value)
ASDF.to_tree(value::WriteSame) = WriteSame(value.value)
ASDF.to_tree(value::WriteMapping) = ASDF.TaggedMapping("tag:example.org/write/mapping-1.0.0", value)

@testset "write conversion protocol" begin
    shallow = ASDF.to_tree(WriteParent(WriteValue(3)))
    @test shallow["child"] isa WriteValue

    converted = ASDF._convert_tree(WriteParent(WriteValue(3)))
    @test converted.tag == "tag:example.org/write/parent-1.0.0"
    @test converted["child"].tag == "tag:example.org/write/value-1.0.0"
    @test ASDF._convert_tree(WriteAlias(WriteValue(4)))["value"] == 4

    source = OrderedDict("tuple" => (WriteValue(5),), "named" => (child = WriteValue(6),))
    tree = ASDF._convert_tree(source)
    @test tree["tuple"][1]["value"] == 5
    @test tree["named"]["child"]["value"] == 6
    @test source["tuple"][1] isa WriteValue

    # A hook may tag its own mapping input without tripping the cycle guard.
    tagged = ASDF._convert_tree(WriteMapping(OrderedDict{String, Any}("child" => WriteValue(7))))
    @test tagged.tag == "tag:example.org/write/mapping-1.0.0"
    @test tagged["child"]["value"] == 7

    # Symbols are written as strings, both as keys and as values.
    @test ASDF._convert_tree(OrderedDict(:unit => :s)) == OrderedDict("unit" => "s")

    cyclic_mapping = OrderedDict{Any, Any}()
    cyclic_mapping["self"] = cyclic_mapping
    cyclic_sequence = Any[]
    push!(cyclic_sequence, cyclic_sequence)
    @test_throws "cyclic ASDF write conversion" ASDF._convert_tree(cyclic_mapping)
    @test_throws "cyclic ASDF write conversion" ASDF._convert_tree(cyclic_sequence)
    @test_throws "cyclic ASDF write conversion" ASDF._convert_tree(WriteLoop())
    @test_throws "nested more than 1000 levels deep" ASDF._convert_tree(WriteSame(1))
    @test_throws "not supported by the ASDF writer" ASDF._convert_tree(UnsupportedWriteValue())
    @test_throws "keys must be booleans, integers, strings, or symbols" ASDF._convert_tree(OrderedDict(WriteValue(1) => 2))
    @test_throws "wrap Matrix" ASDF._convert_tree([WriteValue(1) WriteValue(2)])
end

@testset "heterogeneous document writing" begin
    data = reshape(collect(1.0:12.0), 3, 4)
    document = OrderedDict(
        "roman" => OrderedDict(
            "meta" => OrderedDict("model" => WriteParent(WriteValue(9)), "description" => "nested"),
            "data" => WriteBlock(data),
        ),
        "name" => "product",
        :band => :F150W,
        "observed" => Date(2024, 3, 5),
        "history" => Any[OrderedDict("time" => DateTime(2024, 3, 5, 6, 7, 8), "note" => nothing)],
    )

    mktempdir() do directory
        filename = joinpath(directory, "custom.asdf")
        ASDF.write_file(filename, document)
        loaded = ASDF.load_file(filename; extensions = true)

        @test collect(keys(loaded.metadata)) == ["roman", "name", "band", "observed", "history", "asdf_library"]
        @test loaded["band"] == "F150W"
        @test loaded["observed"] == Date(2024, 3, 5)
        @test loaded["history"][1]["time"] == DateTime(2024, 3, 5, 6, 7, 8)
        @test loaded["history"][1]["note"] === nothing
        @test loaded["roman"]["meta"]["model"]["child"]["value"] == 9
        @test loaded["roman"]["data"]["data"][] == data
        @test !haskey(document, "asdf_library")
        @test document["roman"]["meta"]["model"] isa WriteParent
        @test document["roman"]["data"] isa WriteBlock
    end
end
