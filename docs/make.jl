using Documenter, PicoHTTPParser

makedocs(modules = [PicoHTTPParser],
         sitename = "PicoHTTPParser.jl",
         authors = "Abraham Jaimes",
         format = Documenter.HTML(),
         repo = Remotes.GitHub("AbrJA", "PicoHTTPParser.jl"),
         pages = ["index.md", "api.md"]
         )

deploydocs(
    repo = "github.com/AbrJA/PicoHTTPParser.jl",
    push_preview = true,
)
