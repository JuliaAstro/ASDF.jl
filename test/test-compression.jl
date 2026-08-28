@testset "LZ4 chunked codec" begin
    x = rand(UInt8(0):UInt8(3), 10_000)
    enc = ASDF.encode_Lz4(x; chunk_size = 1024) # 10 chunks
    @test ASDF.decode_Lz4(enc, length(x)) == x
    @test ASDF.decode_Lz4(ASDF.encode_Lz4(UInt8[]), 0) == UInt8[]
    @test_throws "LZ4 chunk" ASDF.decode_Lz4(enc[1:(end - 1)], length(x))
    @test_throws "LZ4 chunk" ASDF.decode_Lz4(enc[1:2], length(x))
end

#=
    Regenerate lz4(f).asdf

Run the below to generate the test files used by this testset.
Needs: pip install asdf lz4 "asdf_compression[lz4f] @ git+https://github.com/asdf-format/asdf-compression"

```python
import asdf
import numpy as np

arr = np.arange(2048, dtype=np.int64)  # 16 KiB
# lz4: stock asdf's chunked block format, 16 chunks of 128 elements; lz4f: asdf-compression's LZ4 frame
for label, kwargs in (("lz4", {"compression_block_size": 1024}), ("lz4f", {})):
    af = asdf.AsdfFile({"arr": arr})
    af.set_array_compression(af["arr"], label, **kwargs)
    af.write_to(f"{label}.asdf")

```
=#
@testset "Python-generated LZ4 fixtures" begin
    for (name, key) in ("lz4" => ASDF.C_Lz4, "lz4f" => ASDF.C_Lz4F)
        af = ASDF.load_file(joinpath("data", "asdf-1.6.0", name * ".asdf"))
        @test af.lazy_block_headers.block_headers[1].compression == ASDF.compression_keys[key]
        @test af["arr"][] == 0:2047
    end
end
