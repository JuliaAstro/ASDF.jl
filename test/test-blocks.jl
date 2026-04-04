function test_read_block_header(msg; kwargs...)
    io = make_raw_header(; kwargs...) |> IOBuffer
    @test_throws msg ASDF.read_block_header(io, Int64(0); validate_checksum = true)
end

function test_read_block(msg; kwargs...)
    @test_throws msg begin
        header = make_block_header(UInt8[5, 6, 7, 8]; kwargs...)
        ASDF.read_block(header)
    end
end

@testset "read_block_header" begin
    test_read_block_header("Number of bytes read from stream does not match length of header";
        incomplete = true,
    )
    test_read_block_header("Block does not start with magic number";
        magic = UInt8[0xd3, 0x42, 0x4c, 0x4c],
    )
    test_read_block_header("ASDF.jl does not yet support streamed blocks";
        flags = UInt32(1),
    )
    test_read_block_header("ASDF file header incorrectly specifies amount of space to use";
        allocated_size = UInt64(5),
        used_size = UInt64(10),
    )
end

@testset "read_block" begin
    test_read_block("Number of bytes read from `header` does not match length of `data`";
        allocated_size = UInt64(16),
        used_size = UInt64(16),
        data_size = UInt64(16),
    )
    test_read_block("Checksum mismatch in ASDF file header";
        checksum = fill(0xFF, 16),
    )
    test_read_block("Invalid compression format found: C_Blosc2";
        compression = ASDF.C_Blosc2,
    )
    test_read_block("Actual data size different from declared data size in header.";
        data_size = UInt64(9),
    )
end

@testset "construction" begin
    b = ASDF.Blocks()
    @test isempty(b)
    push!(b.arrays, ASDF.NDArrayWrapper(ones(Float32, 2)))
    @test !isempty(b)
end
