function make_raw_header(;
    incomplete   = false,
    magic        = ASDF.block_magic_token,
    header_size  = UInt16(48),
    flags        = UInt32(0),
    compression  = ASDF.compression_keys[ASDF.C_None],
    allocated_size = UInt64(0),
    used_size    = UInt64(0),
    data_size    = UInt64(0),
    checksum     = zeros(UInt8, 16),
)
    if incomplete
        hdr = zeros(UInt8, 10) # Incomplete, invalid file
    else
        hdr = zeros(UInt8, 6 + 48)
        hdr[1:4]   .= magic
        hdr[5:6]   .= ASDF.native2big_U16(header_size)
        hdr[7:10]  .= ASDF.native2big_U32(flags)
        hdr[11:14] .= compression
        hdr[15:22] .= ASDF.native2big_U64(allocated_size)
        hdr[23:30] .= ASDF.native2big_U64(used_size)
        hdr[31:38] .= ASDF.native2big_U64(data_size)
        hdr[39:54] .= checksum
    end
    return hdr
end

function make_block_header(; kwargs...)
    io = IOBuffer()
    write(io, make_raw_header(; kwargs...))
    write(io, zeros(UInt8)) # Hard-coded payload
    seekstart(io)
    return ASDF.read_block_header(io, Int64(0))
end

function test_read_block_header(msg; kwargs...)
    io = make_raw_header(; kwargs...) |> IOBuffer
    @test_throws msg ASDF.read_block_header(io, Int64(0))
end

function test_read_block(msg; kwargs...)
    @test_throws msg begin
        header = make_block_header(; kwargs...)
        ASDF.read_block(header)
    end
end

function yea()
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
            compression = ASDF.compression_keys[ASDF.C_Blosc2],
        )
        test_read_block("Actual data size different from declared data size in header.";
            data_size = UInt64(9),
        )
    end
end
