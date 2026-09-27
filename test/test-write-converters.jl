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
struct WriteSame
    value::Int
end
struct UnsupportedWriteValue end

ASDF.to_tree(value::WriteValue) = ASDF.TaggedMapping("tag:example.org/write/value-1.0.0", OrderedDict("value" => value.value))
ASDF.to_tree(value::WriteParent) = ASDF.TaggedMapping("tag:example.org/write/parent-1.0.0", OrderedDict("child" => value.child))
ASDF.to_tree(value::WriteAlias) = value.value
ASDF.to_tree(value::WriteBlock) = ASDF.TaggedMapping("tag:example.org/write/block-1.0.0", OrderedDict("data" => ASDF.NDArrayWrapper(value.data; compression=ASDF.C_Zlib)))
ASDF.to_tree(value::WriteLoop) = OrderedDict("self" => value)
ASDF.to_tree(value::WriteSame) = WriteSame(value.value)

@testset "write conversion protocol" begin
    shallow = ASDF.to_tree(WriteParent(WriteValue(3)))
    @test shallow["child"] isa WriteValue

    converted = ASDF._convert_tree(WriteParent(WriteValue(3)))
    @test converted.tag == "tag:example.org/write/parent-1.0.0"
    @test converted["child"].tag == "tag:example.org/write/value-1.0.0"
    @test ASDF._convert_tree(WriteAlias(WriteValue(4)))["value"] == 4

    source = OrderedDict("tuple" => (WriteValue(5),), "named" => (child=WriteValue(6),))
    tree = ASDF._convert_tree(source)
    @test tree["tuple"][1]["value"] == 5
    @test tree["named"]["child"]["value"] == 6
    @test source["tuple"][1] isa WriteValue

    cyclic_mapping = OrderedDict{Any,Any}()
    cyclic_mapping["self"] = cyclic_mapping
    cyclic_sequence = Any[]
    push!(cyclic_sequence, cyclic_sequence)
    @test_throws "cyclic ASDF write conversion" ASDF._convert_tree(cyclic_mapping)
    @test_throws "cyclic ASDF write conversion" ASDF._convert_tree(cyclic_sequence)
    @test_throws "cyclic ASDF write conversion" ASDF._convert_tree(WriteLoop())
    @test_throws "must return a supported ASDF tree node" ASDF._convert_tree(WriteSame(1))
    @test_throws "not supported by the ASDF writer" ASDF._convert_tree(UnsupportedWriteValue())
    @test_throws "keys must be booleans, integers, or strings" ASDF._convert_tree(OrderedDict(WriteValue(1) => 2))
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
    )

    mktempdir() do directory
        filename = joinpath(directory, "custom.asdf")
        ASDF.write_file(filename, document)
        loaded = ASDF.load_file(filename; extensions=true)

        @test collect(keys(loaded.metadata)) == ["roman", "name", "asdf_library"]
        @test loaded["roman"]["meta"]["model"]["child"]["value"] == 9
        @test loaded["roman"]["data"]["data"][] == data
        @test !haskey(document, "asdf_library")
        @test document["roman"]["meta"]["model"] isa WriteParent
        @test document["roman"]["data"] isa WriteBlock
    end
end
