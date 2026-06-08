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

    # Should fall back to an `AbstractDict`
    af = load_tag(tag_unknown_mapping; extensions = true)
    obj = af.metadata["custom_obj"]
    @test obj isa AbstractDict
    @test obj["width"]  == 42
    @test obj["height"] == 7

    # Known key still parsed as normal
    @test af.metadata["known_key"] == "hello"

    # Two loads must not cross-contaminate via shared/global state: load a second file with a
    # different value *after* the first, then check the first still reads its own value.
    af1 = load_tag(tag_unknown_mapping; extensions = true)
    af2 = load_tag(replace(tag_unknown_mapping, "width: 42" => "width: 99"); extensions = true)
    @test af1.metadata["custom_obj"]["width"] == 42
    @test af2.metadata["custom_obj"]["width"] == 99
end

@testset "unknown sequence" begin
    tag_unknown_sequence = """
    known_key: hello
    custom_list: !<tag:example.org:mylib/series-1.0.0>
      - alpha
      - beta
      - gamma
    """

    # The default `extensions = false` case
    @test_throws Exception load_tag(tag_unknown_sequence; extensions = false)

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

    # The default `extensions = false` case
    @test_throws Exception load_tag(tag_unknown_scalar; extensions = false)

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

@testset "unrecognized tag warning" begin
    tag_unknown_scalar = """
    custom_value: !<tag:example.org:mylib/quantity-1.0.0> 3.14
    """

    # A warning naming the offending tag should be emitted on load.
    @test_logs (:warn, r"Unrecognized tag") match_mode = :any begin
        load_tag(tag_unknown_scalar; extensions = true)
    end

    # The same tag repeated should warn only once per load. Count the matching warnings
    # directly rather than via a strict `@test_logs`, so unrelated records do not interfere.
    # On Windows, `load_tag`'s retained file handle makes `mktempdir` emit a "cleanup" error.
    tag_repeated = """
    a: !<tag:example.org:mylib/quantity-1.0.0> 1
    b: !<tag:example.org:mylib/quantity-1.0.0> 2
    """
    logs, _ = Test.collect_test_logs() do
        load_tag(tag_repeated; extensions = true)
    end
    @test count(r -> occursin("Unrecognized tag", string(r.message)), logs) == 1
end

@testset "unknown tag roundtrip" begin
    # Loading with `extensions = true`, writing back out, and reloading must preserve both the
    # unrecognized tag and the value, for mappings, sequences, and scalars alike.
    tag_unknown_all = """
    mapping_node: !<tag:example.org:mylib/widget-1.0.0>
      width: 42
      height: 7
    sequence_node: !<tag:example.org:mylib/series-1.0.0>
      - alpha
      - beta
    scalar_node: !<tag:example.org:mylib/quantity-1.0.0> 3.14
    empty_mapping: !<tag:example.org:mylib/widget-1.0.0> {}
    empty_sequence: !<tag:example.org:mylib/series-1.0.0> []
    """

    af = load_tag(tag_unknown_all; extensions = true)
    af2 = mktempdir() do dir
        path = joinpath(dir, "roundtrip.asdf")
        ASDF.write_file(path, af.metadata)
        ASDF.load_file(path; extensions = true)
    end
    md = af2.metadata

    @test md["mapping_node"] isa ASDF.TaggedMapping
    @test md["mapping_node"].tag == "tag:example.org:mylib/widget-1.0.0"
    @test md["mapping_node"]["width"] == 42
    @test md["mapping_node"]["height"] == 7

    @test md["sequence_node"] isa ASDF.TaggedSequence
    @test md["sequence_node"].tag == "tag:example.org:mylib/series-1.0.0"
    @test md["sequence_node"][1] == "alpha"
    @test md["sequence_node"][2] == "beta"

    @test md["scalar_node"] isa ASDF.TaggedScalar
    @test md["scalar_node"].tag == "tag:example.org:mylib/quantity-1.0.0"
    @test md["scalar_node"] == "3.14"

    # Empty tagged collections must survive too (they serialize inline as `{}` / `[]`).
    @test md["empty_mapping"] isa ASDF.TaggedMapping
    @test md["empty_mapping"].tag == "tag:example.org:mylib/widget-1.0.0"
    @test isempty(md["empty_mapping"])

    @test md["empty_sequence"] isa ASDF.TaggedSequence
    @test md["empty_sequence"].tag == "tag:example.org:mylib/series-1.0.0"
    @test isempty(md["empty_sequence"])
end

@testset "core container tags roundtrip" begin
    # The known core container tags (`software`, `extension_metadata`) carry no special behavior,
    # but their tag is provenance worth keeping. They are retained even with the default
    # `extensions = false`, and survive a write/reload in the `!core/...` shorthand.
    tag_history = """
    history:
      extensions:
      - !core/extension_metadata-1.0.0
        extension_class: "asdf.extension._manifest.ManifestExtension"
        extension_uri: "asdf://asdf-format.org/core/extensions/core-1.6.0"
        software: !core/software-1.0.0
          name: "asdf"
          version: "4.1.0"
    """

    af = load_tag(tag_history)  # extensions = false
    ext = af.metadata["history"]["extensions"][1]
    @test ext isa ASDF.TaggedMapping
    @test ext.tag == "tag:stsci.edu:asdf/core/extension_metadata-1.0.0"
    @test ext["software"] isa ASDF.TaggedMapping
    @test ext["software"].tag == "tag:stsci.edu:asdf/core/software-1.0.0"
    @test ext["extension_class"] == "asdf.extension._manifest.ManifestExtension"

    af2 = mktempdir() do dir
        path = joinpath(dir, "roundtrip.asdf")
        ASDF.write_file(path, af.metadata)
        # The tag is written in the `!core/...` shorthand declared by the `%TAG` directive.
        @test occursin("!core/extension_metadata-1.0.0", read(path, String))
        ASDF.load_file(path)
    end
    ext2 = af2.metadata["history"]["extensions"][1]
    @test ext2.tag == "tag:stsci.edu:asdf/core/extension_metadata-1.0.0"
    @test ext2["software"].tag == "tag:stsci.edu:asdf/core/software-1.0.0"
end

@testset "tagged node accessors" begin
    # The `Tagged*` wrappers delegate their collection / string interfaces to the wrapped
    # value. Loading round-trips them (see the roundtrip testset above), but the individual
    # delegated methods are pinned down directly here so they stay covered across platforms.
    tm  = ASDF.TaggedMapping("tag:example.org:mylib/widget-1.0.0", Dict("a" => 1, "b" => 2))
    ts  = ASDF.TaggedSequence("tag:example.org:mylib/series-1.0.0", ["alpha", "beta", "gamma"])
    tsc = ASDF.TaggedScalar("tag:example.org:mylib/quantity-1.0.0", "3.14")

    # TaggedMapping behaves as its underlying dict.
    @test length(tm) == 2
    @test tm["a"] == 1
    @test haskey(tm, "b")
    @test !haskey(tm, "missing")
    @test get(tm, "b", 0) == 2
    @test get(tm, "missing", -1) == -1

    # TaggedSequence behaves as its underlying vector, with linear indexing.
    @test Base.IndexStyle(typeof(ts)) == IndexLinear()
    @test Base.IndexStyle(ASDF.TaggedSequence) == IndexLinear()
    @test size(ts) == (3,)
    @test ts[2] == "beta"

    # TaggedScalar behaves as its underlying string.
    @test ncodeunits(tsc) == ncodeunits("3.14")
    @test codeunit(tsc) == UInt8
    @test codeunit(tsc, 1) == codeunit("3.14", 1)
    @test isvalid(tsc, 1)
    @test !isvalid(tsc, 99)
    @test tsc == "3.14"
end
