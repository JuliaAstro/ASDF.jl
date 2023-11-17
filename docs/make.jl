# Generate documentation with this command:
# (cd docs && julia make.jl)

push!(LOAD_PATH, "..")

using Documenter
using ASDF2

makedocs(; sitename="ASDF2", format=Documenter.HTML(), modules=[ASDF2])

deploydocs(; repo="github.com/eschnett/ASDF2.jl.git", devbranch="main", push_preview=true)
