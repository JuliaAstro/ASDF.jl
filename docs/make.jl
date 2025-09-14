# Generate documentation with this command:
# (cd docs && julia make.jl)

push!(LOAD_PATH, "..")

using ASDF2
using Documenter
using Documenter.Remotes: GitHub

makedocs(;
    modules = [ASDF2],
    authors = "Erik Schnetter",
    repo = GitHub("JuliaAstro/ASDF2.jl"),
    sitename = "ASDF2.jl",
    format = Documenter.HTML(
        prettyurls = true,
        canonical = "https://juliaastro.org/ASDF2/stable/",
    ),
)

deploydocs(;
    repo = "github.com/JuliaAstro/ASDF2.jl",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#"], # Restrict to minor releases
)
