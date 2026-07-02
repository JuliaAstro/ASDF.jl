using ASDF
using Documenter, DocumenterInterLinks
using Documenter.Remotes: GitHub

links = InterLinks(
    "PythonCall" => "https://juliapy.github.io/PythonCall.jl/stable/",
)

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
        "Interoperability" => "interop.md",
        "API" => "api.md",
    ],
    doctest = false,
    plugins = [links],
)

deploydocs(;
    repo = "github.com/JuliaAstro/ASDF.jl",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#"], # Restrict to minor releases
)
