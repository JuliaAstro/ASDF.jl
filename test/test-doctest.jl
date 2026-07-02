using Documenter

DocMeta.setdocmeta!(ASDF, :DocTestSetup, :(using ASDF); recursive = true)

doctest(ASDF)
