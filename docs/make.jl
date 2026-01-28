# Generate documentation with this command:
# (cd docs && julia make.jl)

push!(LOAD_PATH, "..")

using ASDF
using Documenter
using Documenter.Remotes: GitHub

makedocs(;
    modules = [ASDF],
    authors = "Erik Schnetter",
    repo = GitHub("JuliaAstro/ASDF.jl"),
    sitename = "ASDF.jl",
    format = Documenter.HTML(
        prettyurls = true,
        canonical = "https://juliaastro.org/ASDF/stable/",
    ),
)

deploydocs(;
    repo = "github.com/JuliaAstro/ASDF.jl",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#"], # Restrict to minor releases
)
