# Support for `JuliaTestItems.toml`, the config file that scopes which files are
# searched for test items.
#
# This is a port of the parts of JuliaWorkspaces' `src/config_common.jl` and
# `src/layer_testitems.jl` that decide file selection, minus the diagnostics
# layer: the language server reports problems in a config file as diagnostics,
# whereas here a bad config is reported with `@warn` and then ignored, so that a
# typo in the config never stops a test run.
#
# Keeping the semantics identical to JuliaWorkspaces matters, because the same
# config file decides which test items VS Code shows and which test items
# `@run_package_tests` runs.

# ── Glob matching ───────────────────────────────────────────────────────────

"""
    struct GlobPattern

A compiled gitignore-style glob. `*` matches within a path segment, `**` spans
segments, `?` matches a single non-separator character, and `[...]` is a
character class. A leading `/` anchors the pattern to the config file's
directory; a pattern containing no `/` matches at any depth. A trailing `/`
makes the pattern match everything below that directory.
"""
struct GlobPattern
    pattern::String
    regex::Regex
end

GlobPattern(pattern::AbstractString) = GlobPattern(String(pattern), _glob_to_regex(pattern))

function _glob_to_regex(pattern::AbstractString)
    pat = replace(String(pattern), '\\' => '/')

    dir_only = endswith(pat, '/')
    dir_only && (pat = chop(pat))

    anchored = startswith(pat, '/')
    anchored && (pat = pat[nextind(pat, 1):end])

    io = IOBuffer()
    print(io, "^")

    # gitignore: a pattern with no separator matches at any depth.
    if !anchored && !occursin('/', pat)
        print(io, "(?:.*/)?")
    end

    i = firstindex(pat)
    stop = lastindex(pat)
    while i <= stop
        c = pat[i]
        if c == '*'
            j = nextind(pat, i)
            if j <= stop && pat[j] == '*'
                # `**/` consumes whole segments; a trailing `**` matches the rest.
                k = nextind(pat, j)
                if k <= stop && pat[k] == '/'
                    print(io, "(?:[^/]*/)*")
                    i = nextind(pat, k)
                else
                    print(io, ".*")
                    i = k
                end
            else
                print(io, "[^/]*")
                i = j
            end
        elseif c == '?'
            print(io, "[^/]")
            i = nextind(pat, i)
        elseif c == '['
            # Copy the character class through, honouring `!`/`^` negation and
            # an escaped `]` as the first member.
            j = nextind(pat, i)
            j <= stop && pat[j] in ('!', '^') && (j = nextind(pat, j))
            j <= stop && pat[j] == ']' && (j = nextind(pat, j))
            while j <= stop && pat[j] != ']'
                j = nextind(pat, j)
            end
            if j > stop
                print(io, "\\[")           # unterminated: treat as a literal
                i = nextind(pat, i)
            else
                cls = pat[i:j]
                startswith(cls, "[!") && (cls = "[^" * cls[3:end])
                print(io, cls)
                i = nextind(pat, j)
            end
        else
            print(io, _regex_escape_char(c))
            i = nextind(pat, i)
        end
    end

    print(io, dir_only ? "/.*\$" : "\$")

    flags = Sys.iswindows() ? "i" : ""
    return Regex(String(take!(io)), flags)
end

const _REGEX_METACHARS = Set{Char}(raw".^$|()[]{}+*?\/")

_regex_escape_char(c::Char) = c in _REGEX_METACHARS ? string('\\', c) : string(c)

matches(g::GlobPattern, relpath::AbstractString) = occursin(g.regex, relpath)

"""
    struct PathFilter

The `include`/`exclude` glob pair of a config file. An empty `include` list
selects everything; `exclude` always wins over `include`.
"""
struct PathFilter
    include::Vector{GlobPattern}
    exclude::Vector{GlobPattern}
end

PathFilter() = PathFilter(GlobPattern[], GlobPattern[])

"""
    path_selected(filter, relpath) -> Bool

Whether `relpath` (relative to the config file's directory, `/`-separated) is
selected by `filter`.
"""
function path_selected(filter::PathFilter, relpath::AbstractString)
    any(g -> matches(g, relpath), filter.exclude) && return false
    isempty(filter.include) && return true
    return any(g -> matches(g, relpath), filter.include)
end

# ── Path helpers ────────────────────────────────────────────────────────────

# Case-insensitive startswith on Windows for path comparison
@static if Sys.iswindows()
    _path_startswith(path, prefix) = startswith(lowercase(path), lowercase(prefix))
else
    _path_startswith(path, prefix) = startswith(path, prefix)
end

function _normalize_dir(dir::AbstractString)
    d = replace(String(dir), '\\' => '/')
    endswith(d, '/') || (d = d * "/")
    return d
end

"""
    config_relative_path(config_dir, path) -> Union{String,Nothing}

`path` expressed relative to `config_dir` with `/` separators, or `nothing` when
`path` is not below `config_dir`.
"""
function config_relative_path(config_dir::AbstractString, path::AbstractString)
    dir = _normalize_dir(config_dir)
    p = replace(String(path), '\\' => '/')
    _path_startswith(p, dir) || return nothing
    return p[nextind(p, lastindex(dir)):end]
end

# ── Config file discovery ───────────────────────────────────────────────────

"""
    is_testitems_config_file(path) -> Bool

Whether `path` names a `JuliaTestItems.toml` file. The comparison is on the
basename only and is case insensitive.
"""
function is_testitems_config_file(path)
    isvalid(path) || return false

    return lowercase(basename(path)) == "juliatestitems.toml"
end

"""
    nearest_config(config_paths, path) -> Union{String,Nothing}

The config file governing `path`: the one in the deepest directory that is a
prefix of `path`'s directory. Only that single file applies — a nested config
file replaces the one above it rather than adding to it.
"""
function nearest_config(config_paths, path::AbstractString)
    target = replace(String(path), '\\' => '/')

    best = nothing
    best_len = -1
    for config_path in config_paths
        dir = _normalize_dir(dirname(config_path))
        _path_startswith(target, dir) || continue
        if length(dir) > best_len
            best = config_path
            best_len = length(dir)
        end
    end

    return best
end

# ── Parsing ─────────────────────────────────────────────────────────────────

# The config format's own version. A file that does not say is version 1.
const CONFIG_FORMAT_VERSION = 1

const _TESTITEMS_CONFIG_TOP_LEVEL_KEYS = ["config-version", "include", "exclude"]

"""
    parse_testitems_config(path) -> PathFilter

Read the `include`/`exclude` globs from a `JuliaTestItems.toml`.

Problems with the file are reported with `@warn` and then ignored: an
unreadable, malformed or too new config file yields a filter that selects
everything, so that a broken config never silently hides test items.
"""
function parse_testitems_config(path)
    table = try
        TOML.parsefile(path)
    catch err
        @warn "Could not read $path, ignoring it." exception = err
        return PathFilter()
    end

    for k in keys(table)
        k in _TESTITEMS_CONFIG_TOP_LEVEL_KEYS || @warn "Invalid test items configuration key `$k` in $path."
    end

    if haskey(table, "config-version")
        v = table["config-version"]
        if !(v isa Integer) || v < 1
            @warn "Invalid `config-version` in $path, expected a positive integer."
        elseif v > CONFIG_FORMAT_VERSION
            @warn "$path declares `config-version = $v`, but this version of TestItemRunner only understands version $CONFIG_FORMAT_VERSION. Update TestItemRunner to use it."
        end
    end

    return PathFilter(_parse_glob_list(table, "include", path), _parse_glob_list(table, "exclude", path))
end

function _parse_glob_list(table, key, path)
    haskey(table, key) || return GlobPattern[]
    v = table[key]
    if !(v isa AbstractVector) || !all(x -> x isa AbstractString, v)
        @warn "Invalid value for `$key` in $path, expected a list of glob strings."
        return GlobPattern[]
    end
    return GlobPattern[GlobPattern(x) for x in v]
end

"""
    testitems_selected(configs, path) -> Bool

Whether `path` is searched for test items, according to the `JuliaTestItems.toml`
governing it. `configs` maps the path of each config file that was found to its
parsed [`PathFilter`](@ref). A file with no governing config file is selected.
"""
function testitems_selected(configs, path::AbstractString)
    isempty(configs) && return true

    config_path = nearest_config(keys(configs), path)
    config_path === nothing && return true

    relative_path = config_relative_path(dirname(config_path), path)
    relative_path === nothing && return true

    return path_selected(configs[config_path], relative_path)
end

@testitem "glob patterns" begin
    using TestItemRunner: GlobPattern, matches

    # A pattern without a separator matches at any depth.
    @test matches(GlobPattern("foo.jl"), "foo.jl")
    @test matches(GlobPattern("foo.jl"), "src/foo.jl")
    @test matches(GlobPattern("foo.jl"), "a/b/foo.jl")
    @test !matches(GlobPattern("foo.jl"), "foo.jl.bak")

    # A leading `/` anchors to the config file's directory.
    @test matches(GlobPattern("/foo.jl"), "foo.jl")
    @test !matches(GlobPattern("/foo.jl"), "src/foo.jl")

    # `*` stays within a segment, `**` spans segments.
    @test matches(GlobPattern("src/*.jl"), "src/foo.jl")
    @test !matches(GlobPattern("src/*.jl"), "src/nested/foo.jl")
    @test matches(GlobPattern("src/**"), "src/nested/foo.jl")
    @test matches(GlobPattern("src/**/*.jl"), "src/a/b/foo.jl")
    @test matches(GlobPattern("src/**/*.jl"), "src/foo.jl")

    # A trailing `/` matches everything below that directory.
    @test matches(GlobPattern("gen/"), "gen/foo.jl")
    @test matches(GlobPattern("gen/"), "gen/a/foo.jl")
    @test !matches(GlobPattern("gen/"), "gen")

    # `?` and character classes.
    @test matches(GlobPattern("f?o.jl"), "foo.jl")
    @test !matches(GlobPattern("f?o.jl"), "fooo.jl")
    @test matches(GlobPattern("[abc].jl"), "a.jl")
    @test !matches(GlobPattern("[abc].jl"), "d.jl")
    @test matches(GlobPattern("[!abc].jl"), "d.jl")
    @test !matches(GlobPattern("[!abc].jl"), "a.jl")

    # Dots are literal, not regex wildcards.
    @test !matches(GlobPattern("foo.jl"), "fooxjl")

    # Backslashes are normalized to forward slashes.
    @test matches(GlobPattern("src\\foo.jl"), "src/foo.jl")
end

@testitem "path_selected" begin
    using TestItemRunner: GlobPattern, PathFilter, path_selected

    # An empty filter selects everything.
    @test path_selected(PathFilter(), "src/foo.jl")

    # An empty include list selects everything not excluded.
    excluded = PathFilter(GlobPattern[], [GlobPattern("test/manual/**")])
    @test path_selected(excluded, "src/foo.jl")
    @test !path_selected(excluded, "test/manual/foo.jl")

    # A non-empty include list restricts to what it names.
    included = PathFilter([GlobPattern("src/**"), GlobPattern("test/**")], GlobPattern[])
    @test path_selected(included, "src/foo.jl")
    @test path_selected(included, "test/foo.jl")
    @test !path_selected(included, "docs/foo.jl")

    # exclude wins over include.
    both = PathFilter([GlobPattern("test/**")], [GlobPattern("test/manual/**")])
    @test path_selected(both, "test/foo.jl")
    @test !path_selected(both, "test/manual/foo.jl")
end

@testitem "nearest_config" begin
    using TestItemRunner: nearest_config, config_relative_path

    configs = ["/a/JuliaTestItems.toml", "/a/b/c/JuliaTestItems.toml"]

    # The deepest enclosing config file wins.
    @test nearest_config(configs, "/a/foo.jl") == "/a/JuliaTestItems.toml"
    @test nearest_config(configs, "/a/b/foo.jl") == "/a/JuliaTestItems.toml"
    @test nearest_config(configs, "/a/b/c/foo.jl") == "/a/b/c/JuliaTestItems.toml"
    @test nearest_config(configs, "/a/b/c/d/foo.jl") == "/a/b/c/JuliaTestItems.toml"

    # A file outside of every config file's directory has no config.
    @test nearest_config(configs, "/z/foo.jl") === nothing
    @test nearest_config(String[], "/a/foo.jl") === nothing

    # Paths are reported relative to the config file's directory.
    @test config_relative_path("/a/b", "/a/b/c/foo.jl") == "c/foo.jl"
    @test config_relative_path("/a/b/", "/a/b/foo.jl") == "foo.jl"
    @test config_relative_path("/a/b", "/z/foo.jl") === nothing
end

@testitem "testitems_selected" begin
    using TestItemRunner: GlobPattern, PathFilter, testitems_selected

    # A file with no config file anywhere above it is selected.
    @test testitems_selected(Dict{String,PathFilter}(), "/a/foo.jl")

    configs = Dict(
        "/a/JuliaTestItems.toml" => PathFilter(GlobPattern[], [GlobPattern("gen/**")]),
        "/a/b/JuliaTestItems.toml" => PathFilter(GlobPattern[], GlobPattern[])
    )

    @test testitems_selected(configs, "/a/foo.jl")
    @test !testitems_selected(configs, "/a/gen/foo.jl")

    # The nearest config replaces the one above it wholesale, so the `gen`
    # exclusion of `/a` does not apply below `/a/b`.
    @test testitems_selected(configs, "/a/b/gen/foo.jl")

    @test testitems_selected(configs, "/z/foo.jl")
end
