# Unit tests for the ASDF string/structured datatype helpers and the write-side
# `infer_asdf_datatype` inference. The reference roundtrips exercise these indirectly,
# but the methods below are pinned down here so they stay covered without large fixtures.

@testset "string datatype interface" begin
    ucs = ASDF.UCS4String((UInt32('h'), UInt32('i'), UInt32(0)))  # null-padded
    asc = ASDF.AsciiString((UInt8('h'), UInt8('i'), UInt8(0)))

    # `codeunit(::Type)` reports the code-unit type for each string view.
    @test codeunit(ucs) == UInt32
    @test codeunit(asc) == UInt8

    # Indexed `codeunit` returns the raw code unit at that position.
    @test codeunit(ucs, 1) == UInt32('h')
    @test codeunit(ucs, 2) == UInt32('i')
    @test codeunit(asc, 1) == UInt8('h')
    @test codeunit(asc, 2) == UInt8('i')

    # Trailing null padding is excluded from the significant length.
    @test ncodeunits(ucs) == 2
    @test ncodeunits(asc) == 2

    # `isvalid` is bounded by the significant length, not the full tuple width.
    @test isvalid(ucs, 1)
    @test isvalid(ucs, 2)
    @test !isvalid(ucs, 3)   # padding byte
    @test !isvalid(ucs, 0)
    @test isvalid(asc, 2)
    @test !isvalid(asc, 3)

    @test ucs == "hi"
    @test asc == "hi"

    # Embedded (non-trailing) nulls are kept: `significant_length` strips only *trailing*
    # nulls, so the significant length runs through to the last non-null code unit.
    ucs_embedded = ASDF.UCS4String((UInt32('h'), UInt32(0), UInt32('i')))
    asc_embedded = ASDF.AsciiString((UInt8('h'), UInt8(0), UInt8('i')))
    @test ncodeunits(ucs_embedded) == 3
    @test ncodeunits(asc_embedded) == 3
    @test ucs_embedded == "h\0i"
    @test asc_embedded == "h\0i"
end

@testset "materialized_eltype" begin
    @test ASDF.materialized_eltype(ASDF.Ucs4Datatype(3)) == ASDF.UCS4String{3}
    @test ASDF.materialized_eltype(ASDF.AsciiDatatype(4)) == ASDF.AsciiString{4}
    # Plain scalar datatypes fall through to the Julia type.
    @test ASDF.materialized_eltype(ASDF.Datatype_float32) == Float32
end

@testset "infer_asdf_datatype" begin
    # Raw `NTuple` byte/codepoint forms map to the ASDF string datatypes.
    @test ASDF.infer_asdf_datatype(NTuple{2, UInt8}) == ASDF.AsciiDatatype(2)
    @test ASDF.infer_asdf_datatype(NTuple{2, UInt32}) == ASDF.Ucs4Datatype(2)

    # The string *views* recover the same datatypes as their backing tuples.
    @test ASDF.infer_asdf_datatype(ASDF.AsciiString{5}) == ASDF.AsciiDatatype(5)
    @test ASDF.infer_asdf_datatype(ASDF.UCS4String{6}) == ASDF.Ucs4Datatype(6)

    # `NamedTuple` becomes a structured datatype with fields inferred recursively.
    sd = ASDF.infer_asdf_datatype(@NamedTuple{x::Float32, label::NTuple{4, UInt8}})
    @test sd isa ASDF.StructuredDatatype
    @test [f.name for f in sd.fields] == ["x", "label"]
    @test sd.fields[1].datatype == ASDF.Datatype_float32
    @test sd.fields[2].datatype == ASDF.AsciiDatatype(4)

    # Plain scalar types defer to the existing dict lookup.
    @test ASDF.infer_asdf_datatype(Int64) == ASDF.Datatype_int64
end

@testset "float16 requires ndarray-1.1.0" begin
    # A `float16` ndarray tagged with the older 1.0.0 schema is non-conformant (the `float16`
    # scalar datatype only exists from ndarray-1.1.0 onward), but other implementations emit it,
    # so we warn and load it leniently rather than reject the file.
    body = """
    arr: !core/ndarray-1.0.0
      data: [1.0, 2.0]
      datatype: float16
      shape: [2]
    """
    mktempdir() do dir
        path = joinpath(dir, "f16.asdf")
        open(path, "w") do io
            print(
                io, """
                #ASDF 1.0.0
                #ASDF_STANDARD 1.6.0
                %YAML 1.1
                %TAG ! tag:stsci.edu:asdf/
                ---
                !core/asdf-1.1.0
                $(body)
                ...
                """
            )
        end
        local af
        @test_logs (:warn, r"older than the schema version") match_mode = :any begin
            af = ASDF.load_file(path)
        end
        # Despite the too-old tag, the array still loads and materializes as `Float16`.
        @test af["arr"][] == Float16[1.0, 2.0]
    end

    # Tagged with 1.1.0, the same array loads cleanly and materializes as `Float16`.
    mktempdir() do dir
        path = joinpath(dir, "f16ok.asdf")
        open(path, "w") do io
            print(
                io, """
                #ASDF 1.0.0
                #ASDF_STANDARD 1.6.0
                %YAML 1.1
                %TAG ! tag:stsci.edu:asdf/
                ---
                !core/asdf-1.1.0
                arr: !core/ndarray-1.1.0
                  data: [1.0, 2.0]
                  datatype: float16
                  shape: [2]
                ...
                """
            )
        end
        af = ASDF.load_file(path)
        arr = af["arr"][]
        # `==` promotes by value, so pin the element type explicitly too.
        @test eltype(arr) == Float16
        @test arr == Float16[1.0, 2.0]
    end
end

@testset "structured records are packed in blocks" begin
    # ASDF, like NumPy, packs the fields of a record, while this `NamedTuple` pads `a` to 8 bytes.
    records = [(a = Int32(7), b = 7.25), (a = Int32(-1), b = 1.0e10), (a = Int32(3), b = -0.5)]
    dt = ASDF.infer_asdf_datatype(eltype(records))
    @test sizeof(eltype(records)) == 16
    @test ASDF.itemsize(dt) == 12
    packed = reduce(vcat, [[reinterpret(UInt8, [r.a]); reinterpret(UInt8, [r.b])] for r in records])
    dir = mktempdir(; cleanup = true)
    # The bytes of a block, read as the given shape and datatype.
    function read_block_as(path, shape, datatype)
        nd = ASDF.load_file(path)["data"]
        return ASDF.NDArray(nd.lazy_block_headers, nd.source, nothing, shape, datatype, nothing, nothing, nothing)
    end

    # Packed bytes read back as records of any shape.
    path = joinpath(dir, "packed.asdf")
    ASDF.write_file(path, Dict{Any, Any}("data" => ASDF.NDArrayWrapper(packed; compression = ASDF.C_None)))
    @test read_block_as(path, [3], dt).strides == [12]
    @test read_block_as(path, [3], dt)[] == records
    @test read_block_as(path, [1, 3], dt)[] == reshape(records, 3, 1)
    @test read_block_as(path, Int64[], dt)[] == fill(records[1])
    @test size(read_block_as(path, [0], dt)[]) == (0,)

    # A big-endian field is swapped after the records are assembled.
    swapped = copy(packed)
    for i in 0:2
        reverse!(swapped, 12i + 1, 12i + 4)
    end
    path = joinpath(dir, "big_endian.asdf")
    ASDF.write_file(path, Dict{Any, Any}("data" => ASDF.NDArrayWrapper(swapped; compression = ASDF.C_None)))
    big_endian = ASDF.StructuredDatatype([ASDF.StructuredField("a", ASDF.Datatype_int32, ASDF.Byteorder_big), dt.fields[2]])
    @test read_block_as(path, [3], big_endian)[] == records

    # Writing packs the records, before any compression.
    for compression in (ASDF.C_None, ASDF.C_Blosc)
        path = joinpath(dir, "records_$compression.asdf")
        ASDF.write_file(path, Dict{Any, Any}("data" => ASDF.NDArrayWrapper(records; compression)))
        @test ASDF.load_file(path)["data"][] == records
        @test read_block_as(path, [36], "uint8")[] == packed
    end
    # An empty array of padded records keeps its eltype both ways, which must not depend on inference.
    path = joinpath(dir, "empty.asdf")
    ASDF.write_file(path, Dict{Any, Any}("data" => ASDF.NDArrayWrapper(records[1:0])))
    @test eltype(ASDF.load_file(path)["data"][]) == eltype(records)
end
