using Documenter, PicoHTTPParser

makedocs(modules = [PicoHTTPParser],
         sitename = "PicoHTTPParser.jl",
         authors = "Abraham Jaimes",
         format = Documenter.HTML()
         )

deploydocs(
    repo = "github.com/AbrJA/PicoHTTPParser.jl",
    target = "build",
    deps   = nothing,
    make   = nothing,
    push_preview = true,
)
