using Documenter, PicoHTTPParser

makedocs(modules = [PicoHTTPParser],
         sitename = "PicoHTTPParser.jl",
         format = Documenter.HTML()
         )

deploydocs(
    repo = "github.com/AbrJA/PicoHTTPParser.jl.git",
    target = "build",
    deps   = nothing,
    make   = nothing,
    push_preview = true,
)
