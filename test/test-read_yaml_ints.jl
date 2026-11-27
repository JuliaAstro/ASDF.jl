function write_asdf(dir, body)
    path = joinpath(dir, "temp.asdf")
    open(path, "w") do io
        print(
            io,
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

# YAML 1.1 integers as ASDF files hold them: a leading-zero run is octal only if every digit is octal, and a
# string otherwise (JuliaData/YAML.jl#41, #247; fixed in #252, YAML 0.4.18).
@testset "leading-zero integers" begin
    meta = mktempdir() do dir
        ASDF.load_file(
            write_asdf(
                dir, """
                obs_id: 01054030080010010041
                visit: 089
                octal: 0105
                decimal: 105
                signed: -012
                hex: 0x1F
                zero: 0
                quoted: "0105"
                float: 0.5
                """
            )
        ).metadata
    end
    @test meta["obs_id"] == "01054030080010010041"
    @test meta["visit"] == "089"
    @test meta["octal"] === 69          # 0105 in base 8
    @test meta["decimal"] === 105
    @test meta["signed"] === -12
    @test meta["hex"] === 0x1f % Int
    @test meta["zero"] === 0
    @test meta["quoted"] == "0105"
    @test meta["float"] === 0.5
end
