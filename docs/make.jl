using Documenter

makedocs(
    sitename = "AktaPrime.jl",
    authors = "Waudby lab",  # TODO: set full author list
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
    warnonly = true,   # don't fail the build on a stray cross-reference
    pages = [
        "Home" => "index.md",
        "Installation" => "installation.md",
        "Acquisition" => "acquisition.md",
        "Viewing results" => "viewing.md",
        "Demo mode" => "demo.md",
    ],
)

deploydocs(
    repo = "github.com/waudbylab/AktaPrime.jl.git",
    devbranch = "main",
)
