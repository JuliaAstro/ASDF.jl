using ASDF
using Documenter
using Documenter.Remotes: GitHub

DocMeta.setdocmeta!(ASDF, :DocTestSetup, setup; recursive = true)

makedocs(;
    modules = [ASDF],
    authors = "Erik Schnetter",
    repo = GitHub("JuliaAstro/ASDF.jl"),
    sitename = "ASDF.jl",
    format = Documenter.HTML(
        canonical = "https://juliaastro.org/ASDF/stable/",
    ),
    pages = [
        "Home" => "index.md",
        "Introduction" => "intro.md",
        "Examples" => [
            "JWST" => "examples/jwst.md",
            "Roman" => "examples/roman.md",
    ],
        "API" => "api.md",
    ],
)

deploydocs(;
    repo = "github.com/JuliaAstro/ASDF.jl",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#"], # Restrict to minor releases
)
