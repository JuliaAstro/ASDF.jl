using ASDF2
using Test
using YAML

asdf = ASDF2.load_file("/tmp/blue_voltage.00000000.asdf")
println(YAML.write(asdf.metadata))

for block_header in asdf.block_headers
    data = ASDF2.read_block(block_header)
    @show length(data)
end
