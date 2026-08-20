using Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

using GitHub, Query, LibGit2, TOML

creds = LibGit2.GitCredential(GitConfig(), "https://github.com")
creds.password===nothing && error("Did not find credentials for github.com in the git credential manager.")
myauth = GitHub.authenticate(read(creds.password, String))
Base.shred!(creds.password)

packages = Dict(
    "JuliaSyntax" => "JuliaLang/JuliaSyntax.jl",
    "TestItemDetection" => "julia-vscode/TestItemDetection.jl",
)

latest_versions = Dict{String,VersionNumber}()
current_versions =  Dict{String,VersionNumber}()

for (pkg,github_location) in packages
    max_version = GitHub.references(github_location, auth=myauth)[1] |>
        @map(_.ref) |>
        @filter(!isnothing(_) && startswith(_, "refs/tags/v")) |>
        @map(VersionNumber(_[12:end])) |>
        maximum

    latest_versions[pkg] = max_version

    project_content = TOML.parsefile(joinpath(@__DIR__, "../packages/$pkg/Project.toml"))
    current_version = VersionNumber(project_content["version"])

    current_versions[pkg] = current_version
    println("Package: $pkg, latest version: $max_version, current version: $current_version")
end

for (pkg,github_location) in packages
    latest_version = latest_versions[pkg]
    current_version = current_versions[pkg]


    if latest_version != current_version
        run(
            addenv(
                Cmd(
                    `git subtree pull --prefix packages/$pkg https://github.com/$github_location v$latest_version --squash`,
                    dir=normpath(joinpath(@__DIR__, ".."))
                ),
                Dict("GIT_MERGE_AUTOEDIT" => "no")
            )
        )
    end
end
