using ParallelTestRunner: runtests, find_tests, parse_args
using ASDF

# Doctest
using Documenter
DocMeta.setdocmeta!(ASDF, :DocTestSetup, :(using ASDF); recursive = true)
doctest(ASDF)

const init_code = quote
    using ASDF
    using Test
    using YAML

    map_tree(f, x) = f(x)
    map_tree(f, vec::AbstractVector) = [map_tree(f, elem) for elem in vec]
    map_tree(f, dict::AbstractDict) = Dict(key => map_tree(f, val) for (key, val) in dict)

    output(x) = nothing
    function output(arr::ASDF.NDArray)
        println("source: $(arr.source)")
        data = arr[]
        println("    type: $(typeof(data))")
        return println("    size: $(size(data))")
    end

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

    function make_block_header(data_bytes::AbstractVector{UInt8};
        used_size      = UInt64(length(data_bytes)),
        allocated_size = used_size,
        data_size      = UInt64(length(data_bytes)),
        compression    = ASDF.C_None,
        checksum       = zeros(UInt8, 16),
    )
        io = IOBuffer(read=true, write=true)
        write(io, make_raw_header(;
            compression    = ASDF.compression_keys[compression],
            allocated_size,
            used_size,
            data_size,
            checksum,
        ))
        write(io, data_bytes)
        seekstart(io)
        return ASDF.read_block_header(io, Int64(0); validate_checksum = true)
    end
end

args = parse_args(Base.ARGS)
testsuite = find_tests(@__DIR__)

runtests(ASDF, args; testsuite, init_code)
