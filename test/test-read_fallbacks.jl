function write_asdf(dir, body)
    path = joinpath(dir, "temp.asdf")
    open(path, "w") do io
        print(io,
            """
            #ASDF 1.0.0
            #ASDF_STANDARD 1.2.0
            # This is an ASDF file <https://asdf-standard.readthedocs.io/>
            %YAML 1.1
            %TAG ! tag:stsci.edu:asdf/
            ---
            !core/asdf-1.1.0
            $(body)
            ...
            """
        )
    end
    return path
end

load_tag(tag; kwargs...) = mktempdir() do dir
    path = write_asdf(dir, tag)
    af = ASDF.load_file(path; kwargs...)
end

@testset "unknown mapping" begin
    tag_unknown_mapping = """
    known_key: hello
    custom_obj: !<tag:example.org:mylib/widget-1.0.0>
      width: 42
      height: 7
    """

    # The default `extensions = false` case
    @test_throws Exception load_tag(tag_unknown_mapping; extensions = false)
    @test_throws Exception load_tag(tag_unknown_sequence; extensions = false)
    @test_throws Exception load_tag(tag_unknown_scalar; extensions = false)

    # Should fall back to an `AbstractDict`
    af = load_tag(tag_unknown_mapping; extensions = true)
    obj = af.metadata["custom_obj"]
    @test obj isa AbstractDict
    @test obj["width"]  == 42
    @test obj["height"] == 7

    # Known key still parsed as normal
    @test af.metadata["known_key"] == "hello"

    # And loading the file multiple times does not mutate any shared/global state
    af1 = load_tag(tag_unknown_mapping; extensions = true)
    af2 = load_tag(tag_unknown_mapping; extensions = true)
    @test af1.metadata["custom_obj"]["width"] == af2.metadata["custom_obj"]["width"]
end

@testset "unknown sequence" begin
    tag_unknown_sequence = """
    known_key: hello
    custom_list: !<tag:example.org:mylib/series-1.0.0>
      - alpha
      - beta
      - gamma
    """

    # Should fall back to an `AbstractVector`
    af = load_tag(tag_unknown_sequence; extensions = true)
    list = af.metadata["custom_list"]

    @test list isa AbstractVector
    @test length(list) == 3
    @test list[1] == "alpha"
    @test list[2] == "beta"
    @test list[3] == "gamma"

end

@testset "unknown scalar" begin
    tag_unknown_scalar = """
    known_key: hello
    custom_value: !<tag:example.org:mylib/quantity-1.0.0> 3.14
    """

    # Should fall back to an `AbstractString`
    af = load_tag(tag_unknown_scalar; extensions = true)
    value = af.metadata["custom_value"]

    @test value isa AbstractString
    @test value == "3.14"
end

@testset "unknown all" begin
    tag_unknown_all = """
    known_key: hello
    mapping_node: !<tag:example.org:mylib/widget-1.0.0>
      width: 42
      height: 7
    sequence_node: !<tag:example.org:mylib/series-1.0.0>
      - alpha
      - beta
    scalar_node: !<tag:example.org:mylib/quantity-1.0.0> 3.14
    """

    # Fallbacks should also work if all unknowns are present in the same file.
    af = load_tag(tag_unknown_all; extensions = true)
    md = af.metadata

    # Mapping branch
    @test md["mapping_node"] isa AbstractDict
    @test md["mapping_node"]["width"] == 42

    # Sequence branch
    @test md["sequence_node"] isa AbstractVector
    @test md["sequence_node"][1] == "alpha"

    # Scalar branch
    @test md["scalar_node"] isa AbstractString
    @test md["scalar_node"] == "3.14"

    # Known key unaffected
    @test md["known_key"] == "hello"
end
