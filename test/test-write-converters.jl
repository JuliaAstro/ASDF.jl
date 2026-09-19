abstract type AbstractWriteValue end

struct WriteValue <: AbstractWriteValue
    value::Int
end

struct SpecialWriteValue <: AbstractWriteValue
    value::Int
end

struct WriteParent
    child
end

struct WriteSequence
    values::Vector{Any}
end

struct WriteScalar
    value::String
end

struct WriteBlock
    data::Matrix{Float64}
end

struct CyclicWriteValue end

ASDF.to_tree(value::AbstractWriteValue, context::ASDF.WriteContext) = ASDF.TaggedMapping("tag:example.org/write/value-1.0.0", OrderedDict("value" => value.value))
ASDF.to_tree(value::SpecialWriteValue, context::ASDF.WriteContext) = ASDF.TaggedMapping("tag:example.org/write/special-1.0.0", OrderedDict("value" => value.value))
ASDF.to_tree(value::WriteParent, context::ASDF.WriteContext) = ASDF.TaggedMapping("tag:example.org/write/parent-1.0.0", OrderedDict("child" => value.child))
ASDF.to_tree(value::WriteSequence, context::ASDF.WriteContext) = ASDF.TaggedSequence("tag:example.org/write/sequence-1.0.0", value.values)
ASDF.to_tree(value::WriteScalar, context::ASDF.WriteContext) = ASDF.TaggedScalar("tag:example.org/write/scalar-1.0.0", value.value)
ASDF.to_tree(value::WriteBlock, context::ASDF.WriteContext) = ASDF.TaggedMapping("tag:example.org/write/block-1.0.0", OrderedDict("data" => ASDF.NDArrayWrapper(value.data; compression = ASDF.C_Zlib)))
ASDF.to_tree(value::CyclicWriteValue, context::ASDF.WriteContext) = OrderedDict("self" => value)

@testset "write conversion protocol" begin
    shallow = ASDF.to_tree(WriteParent(WriteValue(3)), ASDF.WriteContext())
    @test shallow isa ASDF.TaggedMapping
    @test shallow["child"] isa WriteValue

    parent = ASDF.to_tree(WriteParent(WriteValue(3)))
    @test parent.tag == "tag:example.org/write/parent-1.0.0"
    @test parent["child"] isa ASDF.TaggedMapping
    @test parent["child"].tag == "tag:example.org/write/value-1.0.0"
    @test parent["child"]["value"] == 3

    sequence = ASDF.to_tree(WriteSequence(Any[WriteValue(4), "plain"]))
    @test sequence isa ASDF.TaggedSequence
    @test sequence.tag == "tag:example.org/write/sequence-1.0.0"
    @test sequence[1] isa ASDF.TaggedMapping
    @test sequence[2] == "plain"

    scalar = ASDF.to_tree(WriteScalar("converted"))
    @test scalar isa ASDF.TaggedScalar
    @test scalar.tag == "tag:example.org/write/scalar-1.0.0"
    @test String(scalar) == "converted"

    @test ASDF.to_tree(WriteValue(5)).tag == "tag:example.org/write/value-1.0.0"
    @test ASDF.to_tree(SpecialWriteValue(5)).tag == "tag:example.org/write/special-1.0.0"
end

@testset "recursive write conversion" begin
    tagged = ASDF.TaggedMapping("tag:example.org/write/existing-1.0.0", OrderedDict("child" => WriteValue(6)))
    converted = ASDF.to_tree(tagged)
    @test converted.tag == tagged.tag
    @test converted["child"] isa ASDF.TaggedMapping
    @test tagged["child"] isa WriteValue

    source = OrderedDict("zebra" => WriteValue(7), "apple" => Any[1, WriteValue(8)], "matrix" => [1 2; 3 4])
    plain = ASDF.to_tree(source)
    @test collect(keys(plain)) == collect(keys(source))
    @test plain["zebra"] isa ASDF.TaggedMapping
    @test plain["apple"][2] isa ASDF.TaggedMapping
    @test plain["matrix"] == source["matrix"]
    @test source["zebra"] isa WriteValue
    @test source["apple"][2] isa WriteValue

    cyclic_mapping = OrderedDict{Any, Any}()
    cyclic_mapping["self"] = cyclic_mapping
    @test_throws "cyclic ASDF write conversion" ASDF.to_tree(cyclic_mapping)

    cyclic_sequence = Any[]
    push!(cyclic_sequence, cyclic_sequence)
    @test_throws "cyclic ASDF write conversion" ASDF.to_tree(cyclic_sequence)
    @test_throws "cyclic ASDF write conversion" ASDF.to_tree(CyclicWriteValue())
end

@testset "heterogeneous document writing" begin
    data = reshape(collect(1.0:12.0), 3, 4)
    document = OrderedDict(
        "roman" => OrderedDict(
            "meta" => OrderedDict("model" => WriteParent(SpecialWriteValue(9)), "description" => "nested"),
            "data" => WriteBlock(data),
        ),
        "name" => "product",
    )

    mktempdir() do directory
        filename = joinpath(directory, "custom.asdf")
        ASDF.write_file(filename, document)
        loaded = ASDF.load_file(filename; extensions = true)

        @test collect(keys(loaded.metadata)) == ["roman", "name", "asdf_library"]
        @test loaded["name"] == "product"
        @test loaded["roman"]["meta"]["model"].tag == "tag:example.org/write/parent-1.0.0"
        @test loaded["roman"]["meta"]["model"]["child"].tag == "tag:example.org/write/special-1.0.0"
        @test loaded["roman"]["data"].tag == "tag:example.org/write/block-1.0.0"
        @test loaded["roman"]["data"]["data"][] == data
        @test !haskey(document, "asdf_library")
        @test document["roman"]["meta"]["model"] isa WriteParent
        @test document["roman"]["data"] isa WriteBlock

        save_filename = joinpath(directory, "custom-save.asdf")
        save(save_filename, document)
        saved = ASDF.load_file(save_filename; extensions = true)
        @test saved["roman"]["data"]["data"][] == data
        @test saved["roman"]["meta"]["model"]["child"]["value"] == 9
    end
end
