"""
    TestItemRunner

This module provides functionalities to run `@testitem` tests in a Julia package,
as part of the TestItemRunner.jl package. It supports running individual test items,
which are self-contained units of code written within `@testitem` macros.

# Key Features
- Provides a mechanism to run individual test items in isolation, ensuring that each
  test item is executed in a new Julia module.
- Supports filtering of test items based on custom criteria, and verbose output during testing.
- Integrates with the base test system, and can be utilized in conjunction with the Julia VS Code
  extension or as a standalone test runner.
"""
module TestItemRunner

include("../packages/JuliaSyntax/src/JuliaSyntax.jl")

module TestItemDetection
    import ..JuliaSyntax
    using ..JuliaSyntax: @K_str, kind, children, SyntaxNode

    include("../packages/TestItemDetection/src/packagedef.jl")
end

import Test, TestItems, TOML
using TestItems: @testitem, @testmodule, @testsnippet

include("vendored_code.jl")
include("testitems_config.jl")

export @run_package_tests, @testitem, @testmodule, @testsnippet

function compute_line_column(content, target_pos)
    line = 1
    column = 1

    pos = 1
    while pos < target_pos
        if content[pos] == '\n'
            line += 1
            column = 1
        else
            column += 1
        end

        pos = nextind(content, pos)
    end

    return (line=line, column=column)
end

@testitem "compute_line_column" begin
    using TestItemRunner: compute_line_column
    content = "abc\ndef\nghi"

    @test compute_line_column(content, 1) == (line=1, column=1)
    @test compute_line_column(content, 2) == (line=1, column=2)
    @test compute_line_column(content, 3) == (line=1, column=3)
    @test compute_line_column(content, 5) == (line=2, column=1)
    @test compute_line_column(content, 6) == (line=2, column=2)
    @test compute_line_column(content, 7) == (line=2, column=3)
    @test compute_line_column(content, 9) == (line=3, column=1)
    @test compute_line_column(content, 10) == (line=3, column=2)
    @test compute_line_column(content, 11) == (line=3, column=3)
end

struct TestSetupModuleSet
    setupmodule::Module
    modules::Set{Symbol}
end

function ensure_evaled(test_setup_module_set, filename, code, name, line, column, working_dir)
    if !(name in test_setup_module_set.modules)
        mod = Core.eval(test_setup_module_set.setupmodule, :(module $(Symbol(name)) end))
        code = string('\n'^line, ' '^column, code)
        cd(working_dir) do
            withpath(filename) do
                Base.invokelatest(include_string, mod, code, filename)
            end
        end
    end
    push!(test_setup_module_set.modules, name)
    return
end

"""
    evaluate_skip(mod, filepath, skip)

Evaluate the expression of a `skip` keyword argument that was not a `Bool`
literal, in the module `mod` the test item would run in.

`skip` carries the source text of the expression and its position, so that the
expression is evaluated with the line numbers it has in the original file.
"""
function evaluate_skip(mod, filepath, skip)
    code = string('\n'^(skip.line-1), ' '^(skip.column-1), skip.code)

    result = cd(dirname(filepath)) do
        withpath(filepath) do
            Base.invokelatest(include_string, mod, code, filepath)
        end
    end

    result isa Bool || error("The `skip` keyword argument must evaluate to a `Bool`, but it evaluated to a value of type $(typeof(result)).")

    return result
end

function ensure_setups_evaled(testitem, test_setup_module_set, testsetups)
    working_dir = dirname(testitem.filename)

    for setup in testitem.option_setup
        haskey(testsetups, setup) || error("Test setup $(setup) is not defined.")

        testsetup = testsetups[setup]

        if testsetup.kind == :module
            ensure_evaled(test_setup_module_set, testsetup.filename, testsetup.code, testsetup.name, testsetup.line, testsetup.column, working_dir)
        elseif testsetup.kind != :snippet
            # Snippets are evaluated in the test item's own module by `run_testitem`
            error("Unknown setup type")
        end
    end
end

"""
    release_module_globals!(mod)

Point every global in `mod` at `nothing`, so that whatever the test item bound to one
becomes collectable.

Every test item runs in a module of its own, and Julia cannot unload a module: the module
stays reachable for the life of the process, and so does everything its globals point at.
A test item that binds a large array therefore keeps that array alive for the rest of the
run, which is what #65 reports. The module object itself still leaks — nothing can be done
about that — but its contents do not have to.

Left alone: `eval`, `include` and the module's own name, which the `module` expression
created rather than the test item, and submodules, because a `@testmodule` reached through
one is shared with other test items. Bindings that cannot take `nothing` — a `const` on
Julia before 1.12, a typed global, a name brought in by `using` — are skipped as they come
up, because there is nothing else to try for them.
"""
function release_module_globals!(mod::Module)
    for name in names(mod; all=true)
        (name === :eval || name === :include || name === nameof(mod)) && continue
        # Names Julia generated itself, for closures, generators and macro hygiene
        occursin('#', string(name)) && continue
        isdefined(mod, name) || continue

        try
            getfield(mod, name) isa Module && continue
            # `Core.eval` rather than `setglobal!`, which only exists from Julia 1.9 on
            Core.eval(mod, Expr(:(=), name, nothing))
        catch
        end
    end

    return nothing
end

@testitem "release_module_globals!" begin
    using TestItemRunner: release_module_globals!

    mod = Core.eval(Main, :(module $(gensym()) end))
    Base.include_string(mod, "kept = [1, 2, 3]\nconst pinned = 1\n")

    weak = WeakRef(getfield(mod, :kept))
    release_module_globals!(mod)

    @test getfield(mod, :kept) === nothing

    GC.gc(true)
    GC.gc(true)
    @test weak.value === nothing

    # `eval` and `include` belong to the module rather than to the test item
    @test getfield(mod, :eval) isa Function
    @test getfield(mod, :include) isa Function

    # A submodule is left alone: a `@testmodule` can be reached through one
    inner = Core.eval(mod, :(module Inner end))
    release_module_globals!(mod)
    @test getfield(mod, :Inner) === inner
end

function run_testitem(mod, filepath, use_default_usings, setups, package_name, original_code, line, column, test_setup_module_set, testsetups)
    working_dir = dirname(filepath)

    if use_default_usings
        Core.eval(mod, :(using Test))

        if package_name!=""
            Core.eval(mod, :(using $(Symbol(package_name))))
        end
    end

    for m in setups
        setup_details = testsetups[m]
        if setup_details.kind==:module
            Core.eval(mod, Expr(:using, Expr(:., :., :., nameof(test_setup_module_set.setupmodule), m)))
        elseif setup_details.kind==:snippet
            snippet_code = string('\n'^setup_details.line, ' '^setup_details.column, setup_details.code)
            cd(working_dir) do
                withpath(setup_details.filename) do
                    Base.invokelatest(include_string, mod, snippet_code, setup_details.filename)
                end
            end
        else
            error("Unknown test setup")
        end
    end

    code = string('\n'^(line-1), ' '^(column-1), original_code)

    cd(working_dir) do
        withpath(filepath) do
            Base.invokelatest(include_string, mod, code, filepath)
        end
    end
end

"""
    run_testitem_in_testset(ts, testitem, package_name, test_setup_module_set, testsetups)

Run a single test item, recording its result into the test set `ts` that was
created for it.

A test item that is skipped is recorded as broken, the same result `@test_skip`
produces, so that skipped test items stay visible in the test summary without
failing the run. Anything that goes wrong while preparing the test item, be it
in a test setup or in a `skip` expression, is recorded as an error on the test
item itself instead of aborting the entire test run.
"""
function run_testitem_in_testset(ts, testitem, package_name, test_setup_module_set, testsetups)
    # A literal `skip=true` is honored without creating a module or evaluating
    # any test setups
    if testitem.skip === true
        Test.record(ts, Test.Broken(:skipped, Symbol(testitem.name)))
        return
    end

    mod = nothing

    try
        mod = Core.eval(Main, :(module $(gensym()) end))

        # A `skip` expression is evaluated in the module the test item would run
        # in, but before anything is imported into it, so that checks like
        # `Sys.iswindows()` see the process the tests actually run in
        if testitem.skip !== false && evaluate_skip(mod, testitem.filename, testitem.skip)
            Test.record(ts, Test.Broken(:skipped, Symbol(testitem.name)))
            return
        end

        ensure_setups_evaled(testitem, test_setup_module_set, testsetups)

        run_testitem(mod, testitem.filename, testitem.option_default_imports, testitem.option_setup, package_name, testitem.code, testitem.line, testitem.column, test_setup_module_set, testsetups)
    catch err
        err isa InterruptException && rethrow()
        Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, current_exception_stack(), LineNumberNode(testitem.line, Symbol(testitem.filename))))
    finally
        # `invokelatest` is load bearing: the test item's globals were created by an
        # `include_string` in a newer world, and from this one `names(mod; all=true)`
        # does not list them yet, so a direct call would find nothing to release.
        mod === nothing || Base.invokelatest(release_module_globals!, mod)
    end

    return
end

"""
    has_failure(ts)

Whether the test set `ts` recorded a failure or an error, either directly or in
a test set nested inside it.

This is what `failfast` looks at after each test item. It walks `results` rather
than asking `Test` for the counts, because the shape of the counts that
`Test.get_test_counts` returns changed between Julia versions, while `results`
did not.
"""
function has_failure(ts)
    :results in fieldnames(typeof(ts)) || return false

    for r in ts.results
        if r isa Test.Fail || r isa Test.Error
            return true
        elseif !(r isa Test.Result) && has_failure(r)
            # Anything recorded that is not a `Test.Result` is a nested test set
            return true
        end
    end

    return false
end

@testitem "has_failure" begin
    using TestItemRunner: has_failure

    # The results are pushed rather than recorded, because `Test.record` prints
    # a failure the moment it sees one, and these are not real failures
    passed = Test.DefaultTestSet("passed")
    push!(passed.results, Test.Pass(:test, nothing, nothing, true))
    @test !has_failure(passed)

    # A `Broken` result is what a skipped test item records, and it must not
    # count as a failure
    broken = Test.DefaultTestSet("broken")
    push!(broken.results, Test.Broken(:skipped, :something))
    @test !has_failure(broken)

    errored = Test.DefaultTestSet("errored")
    stack = try
        error("boom")
    catch
        TestItemRunner.current_exception_stack()
    end
    push!(errored.results, Test.Error(:nontest_error, Expr(:tuple), ErrorException("boom"), stack, LineNumberNode(1, Symbol(@__FILE__))))
    @test has_failure(errored)

    # A failure nested one test set deep is still a failure
    outer = Test.DefaultTestSet("outer")
    push!(outer.results, errored)
    @test has_failure(outer)

    # Something without a `results` field is not a test set we can inspect
    @test !has_failure(nothing)
end

# The `skip` keyword argument of a test item is reported by TestItemDetection
# either as a `Bool`, when it was a literal, or as the source range of an
# expression that has to be evaluated in the test process just before the test
# item would run. We resolve that range to the source text plus the position it
# was written at here, while we still have the content of the file at hand.
function skip_details(content, option_skip)
    option_skip isa Bool && return option_skip

    return (code=content[option_skip], compute_line_column(content, first(option_skip))...)
end

# Directory names that are never worth descending into.
const SKIPPED_DIRNAMES = Set([".git", ".svn", ".hg", "node_modules"])

"""
    find_test_files(path)

Find all the Julia files in `path` and its subfolders that are searched for test
items.

Version control and dependency folders are never descended into, and any
`JuliaTestItems.toml` file that is found scopes which of the remaining files are
searched, see [`testitems_selected`](@ref). `path` is the root of that scope:
config files above it are not consulted, just as the language server consults
none above a workspace folder.
"""
function find_test_files(path)
    path = abspath(path)

    julia_files = String[]
    config_files = String[]

    # An explicit walk instead of `walkdir`, because it is hard to stop that from
    # recursing into the directories we want to skip
    remaining_dirs = [path]
    while !isempty(remaining_dirs)
        dir = popfirst!(remaining_dirs)

        entries = try
            readdir(dir)
        catch
            continue
        end

        for entry in entries
            filepath = joinpath(dir, entry)

            descend = try
                !islink(filepath) && isdir(filepath)
            catch
                # Foreign or broken reparse points (for example WSL created
                # symlinks) make `lstat` throw on Julia 1.11 and later, so we
                # skip any entry we cannot stat
                continue
            end

            if descend
                if !(entry in SKIPPED_DIRNAMES)
                    push!(remaining_dirs, filepath)
                end
            elseif is_testitems_config_file(entry)
                push!(config_files, normpath(filepath))
            else
                _, ext = splitext(entry)
                if isvalid(ext) && lowercase(ext) == ".jl"
                    push!(julia_files, normpath(filepath))
                end
            end
        end
    end

    isempty(config_files) && return julia_files

    configs = Dict{String,PathFilter}(i => parse_testitems_config(i) for i in config_files)

    return Base.filter(i -> testitems_selected(configs, i), julia_files)
end

"""
    TestItemTree

A node in the tree that the test summary is organized by.

The tree mirrors the folder structure below the package root: every folder that
contains test items becomes a node, and every file with test items becomes a
leaf that carries them. `Test` renders whatever nesting of test sets it is
handed, so building this tree is all it takes for the summary to show the folder
structure.
"""
mutable struct TestItemTree
    name::String
    # Whether this node came from a folder rather than a file. Only used for
    # ordering, and deliberately not touched by `collapse_tree!`, so that a
    # collapsed `test/runtests.jl` still sorts where the `test` folder sat.
    isdir::Bool
    children::Vector{TestItemTree}
    # Only ever non-empty on a leaf, and a leaf is always a file
    testitems::Vector
end

TestItemTree(name, isdir) = TestItemTree(name, isdir, TestItemTree[], [])

"""
    path_components(path)

Split a path into its individual components, outermost first.

This is what `splitpath` does, which we cannot use because it was only added in
Julia 1.1 while this package still supports Julia 1.0.
"""
function path_components(path)
    components = String[]

    while true
        dir, name = splitdir(path)
        isempty(name) || pushfirst!(components, name)
        (isempty(dir) || dir == path) && break
        path = dir
    end

    return components
end

@testitem "path_components" begin
    using TestItemRunner: path_components

    @test path_components("runtests.jl") == ["runtests.jl"]
    @test path_components(joinpath("test", "runtests.jl")) == ["test", "runtests.jl"]
    @test path_components(joinpath("a", "b", "c.jl")) == ["a", "b", "c.jl"]
    @test path_components("") == String[]

    # An absolute path has to terminate too, even though we only ever hand this
    # relative paths
    @test path_components(abspath(joinpath("a", "b.jl")))[end-1:end] == ["a", "b.jl"]
end

"""
    build_tree(root_name, files)

Build the tree of test items from `files`, a collection of `(path, testitems)`
pairs whose paths are relative to the package root.
"""
function build_tree(root_name, files)
    root = TestItemTree(root_name, true)

    for (path, testitems) in files
        components = path_components(path)
        isempty(components) && continue

        node = root

        for i in 1:length(components)
            component = components[i]
            isdir = i < length(components)

            child = nothing
            for candidate in node.children
                if candidate.name == component && candidate.isdir == isdir
                    child = candidate
                    break
                end
            end

            if child === nothing
                child = TestItemTree(component, isdir)
                push!(node.children, child)
            end

            node = child
        end

        append!(node.testitems, testitems)
    end

    return root
end

@testitem "build_tree" begin
    using TestItemRunner: build_tree

    tree = build_tree("MyPkg", [(joinpath("test", "a", "x.jl"), [1]), (joinpath("test", "y.jl"), [2, 3])])

    @test tree.name == "MyPkg"
    @test [i.name for i in tree.children] == ["test"]

    test_folder = tree.children[1]
    @test test_folder.isdir
    @test isempty(test_folder.testitems)

    # Files in the same folder share their parent
    @test sort([i.name for i in test_folder.children]) == ["a", "y.jl"]

    y = test_folder.children[findfirst(i -> i.name == "y.jl", test_folder.children)]
    @test !y.isdir
    @test y.testitems == [2, 3]

    a = test_folder.children[findfirst(i -> i.name == "a", test_folder.children)]
    @test [i.name for i in a.children] == ["x.jl"]
    @test a.children[1].testitems == [1]
end

"""
    sort_tree!(node)

Order the children of every node below `node`: folders first, then files, each
group alphabetically. Without this the summary would follow the arbitrary order
of the `Dict` the test items were collected in, which can differ between runs.
"""
function sort_tree!(node)
    sort!(node.children, by=i -> (i.isdir ? 0 : 1, i.name))

    for child in node.children
        sort_tree!(child)
    end

    return node
end

@testitem "sort_tree!" begin
    using TestItemRunner: build_tree, sort_tree!

    tree = build_tree("MyPkg", [
        (joinpath("src", "b.jl"), []),
        ("z.jl", []),
        ("a.jl", []),
        (joinpath("test", "c.jl"), []),
    ])
    sort_tree!(tree)

    # Folders come first, and each group is alphabetical
    @test [i.name for i in tree.children] == ["src", "test", "a.jl", "z.jl"]
end

"""
    collapse_tree!(root)

Fold every chain of nodes below `root` that has a single child into one node, so
that a `test` folder holding nothing but `runtests.jl` shows up as a single
`test/runtests.jl` test set rather than as two nested ones.

The root itself is never folded into its child, because it names the package.
"""
function collapse_tree!(root)
    for child in root.children
        collapse_node!(child)
    end

    return root
end

function collapse_node!(node)
    for child in node.children
        collapse_node!(child)
    end

    # The children have already been collapsed, so a single child cannot itself
    # have a single child, and this folds a chain of any length in one pass
    if length(node.children) == 1
        child = node.children[1]

        # Always a forward slash, so that the summary reads the same on Windows
        # as it does everywhere else
        node.name = string(node.name, '/', child.name)
        node.children = child.children
        node.testitems = child.testitems
    end

    return node
end

@testitem "collapse_tree!" begin
    using TestItemRunner: build_tree, sort_tree!, collapse_tree!

    # A folder with a single file folds into one node, a chain of them folds all
    # the way down, and a folder with two children is left alone
    tree = build_tree("MyPkg", [
        (joinpath("test", "runtests.jl"), [1]),
        (joinpath("a", "b", "c", "deep.jl"), [2]),
        (joinpath("many", "one.jl"), []),
        (joinpath("many", "two.jl"), []),
    ])
    sort_tree!(tree)
    collapse_tree!(tree)

    names = [i.name for i in tree.children]
    @test "test/runtests.jl" in names
    @test "a/b/c/deep.jl" in names
    @test "many" in names

    runtests = tree.children[findfirst(i -> i.name == "test/runtests.jl", tree.children)]
    @test isempty(runtests.children)
    @test runtests.testitems == [1]

    many = tree.children[findfirst(i -> i.name == "many", tree.children)]
    @test [i.name for i in many.children] == ["one.jl", "two.jl"]

    # The root keeps its own name even when it has a single child
    single = build_tree("MyPkg", [(joinpath("test", "runtests.jl"), [])])
    collapse_tree!(single)
    @test single.name == "MyPkg"
    @test [i.name for i in single.children] == ["test/runtests.jl"]
end

# Running a test set and finishing it afterwards. Julia 1.13 replaced the
# `push_testset`/`pop_testset` stack with `Test.@with_testset`, and the tree is
# walked recursively, so that difference is shimmed here rather than duplicating
# the whole walk once per version.
@static if VERSION ≤ v"1.13-"
    function with_testset(f, ts)
        Test.push_testset(ts)

        return try
            f()
        finally
            Test.finish(Test.pop_testset())
        end
    end

    function with_root_testset(f, ts)
        Test.push_testset(ts)

        return try
            f()
        finally
            # Outer testset generates report that needs to integrate results from nested (custom) testsets
            Base.invokelatest(Test.finish, Test.pop_testset())
        end
    end
else
    function with_testset(f, ts)
        return try
            Test.@with_testset ts begin
                f()
            end
        finally
            Test.finish(ts)
        end
    end

    function with_root_testset(f, ts)
        return try
            Test.@with_testset ts begin
                f()
            end
        finally
            # Outer testset generates report that needs to integrate results from nested (custom) testsets
            Base.invokelatest(Test.finish, ts)
        end
    end
end

"""
    run_node!(node, package_name, test_setup_module_set, testsetups, verbose, failfast)

Run everything below `node`, creating one test set per node on the way down.

Returns whether the run should stop, which is how `failfast` unwinds out of
every level of the tree while still finishing the test sets that are already
open, so that the summary of the partial run still prints.
"""
function run_node!(node, package_name, test_setup_module_set, testsetups, verbose, failfast)
    if isempty(node.children)
        for testitem in node.testitems
            ts = testset(testitem.name; verbose=verbose)

            with_testset(ts) do
                run_testitem_in_testset(ts, testitem, package_name, test_setup_module_set, testsetups)
                false
            end

            failfast && has_failure(ts) && return true
        end
    else
        for child in node.children
            stop = with_testset(testset(child.name; verbose=verbose)) do
                run_node!(child, package_name, test_setup_module_set, testsetups, verbose, failfast)
            end

            stop && return true
        end
    end

    return false
end

"""
    run_tests(path; filter=nothing, verbose=false)

Run all test items in a directory and its subdirectories.

The test items are organized into a tree of test sets that mirrors the folder
structure below `path`, so that the summary shows where each test item lives.
Returns the finished root test set.

# Arguments
- `path`: The path to the directory containing the tests.
- `filter`: A filter function to apply to the test items.
- `verbose`: Whether to run the tests in verbose mode.
- `failfast`: Whether to stop the test run after the first test item that fails
  or errors. The remaining test items are then not run at all, so they show up
  in neither the summary nor the counts.
"""
function run_tests(path; filter=nothing, verbose=false, failfast=false)
    path = abspath(path)

    # Find package name
    package_name = ""
    package_filename = isfile(joinpath(path, "Project.toml")) ? joinpath(path, "Project.toml") : isfile(joinpath(path, "JuliaProject.toml")) ? joinpath(path, "JuliaProject.toml") : nothing
    if package_filename!==nothing
        try
            project_content = TOML.parsefile(package_filename)

            package_name = get(project_content, "name", "")
        catch
        end
    end

    julia_files = find_test_files(path)

    # Find all @testitems and @testsetup
    testitems = Dict{String,Vector}()
    # testsetups maps @testsetup NAME => (filename, code, name, line, column)
    testsetups = Dict{Symbol,Any}()
    for file in julia_files
        content = read(file, String)

        stream = JuliaSyntax.ParseStream(content; version=VERSION)
        JuliaSyntax.parse!(stream; rule=:all)
        tree = JuliaSyntax.build_tree(JuliaSyntax.SyntaxNode, stream)

        testitems_for_file = []
        testsetups_for_file = []
        errors_for_file = []
        TestItemDetection.find_test_detail!(tree, testitems_for_file, testsetups_for_file, errors_for_file)

        if length(errors_for_file) > 0
            @warn "Error in your test item or test setup definition" file errors=errors_for_file
            error("There is an error in your test item or test setup definition, we are aborting.")
        end

        if length(testitems_for_file) > 0
            testitems[file] = [(filename=file, code=content[i.code_range], name=i.name, option_tags=i.option_tags, option_default_imports=i.option_default_imports, option_setup=i.option_setup, skip=skip_details(content, i.option_skip), compute_line_column(content, i.code_range.start)...) for i in testitems_for_file]
        end
        for i in testsetups_for_file
            testsetups[i.name] = (filename=file, code=content[i.code_range], name=Symbol(i.name), kind=i.kind, compute_line_column(content, i.code_range.start)...)
        end
    end

    # Filter @testitems
    if filter !== nothing
        for file in keys(testitems)
            testitems[file] = Base.filter(i -> filter((filename=file, name=i.name, tags=i.option_tags)), testitems[file])
            isempty(testitems[file]) && pop!(testitems, file)
        end
    end

    # Organize the test items into a tree that mirrors the folder structure, so
    # that the summary shows where in the package each test item lives
    root = build_tree(
        isempty(package_name) ? "Package" : package_name,
        [(relpath(file, path), items) for (file, items) in pairs(testitems)]
    )
    sort_tree!(root)
    collapse_tree!(root)

    # Run testitems
    test_setup_module = Core.eval(Main, :(module $(gensym()) end))
    test_setup_module_set = TestSetupModuleSet(test_setup_module, Set{Symbol}())

    root_ts = testset(root.name; verbose=verbose)

    with_root_testset(root_ts) do
        run_node!(root, package_name, test_setup_module_set, testsetups, verbose, failfast)
    end

    return root_ts
end

"""
    @run_package_tests(ex...)

Run all test items in a package, using optional filter and verbosity arguments.

# Usage
```julia
@run_package_tests filter=<filter_function>, verbose=<bool>, failfast=<bool>
```

```julia
@run_package_tests filter=ti->!(:skipci in ti.tags)
```

# Arguments
- `filter`: An optional filter function to apply to the test items.
- `verbose`: An optional argument to specify verbosity.
- `failfast`: An optional argument to stop the run after the first test item
  that fails or errors.
"""
macro run_package_tests(ex...)
    kwargs = []

    for i in ex
        if i isa Expr && i.head==:(=) && length(i.args)==2 && i.args[1] in (:filter, :verbose, :failfast)
            push!(kwargs, esc(i))
        else
            error("Invalid argument")
        end
    end

    :(run_tests(joinpath($(dirname(string(__source__.file))), ".."); $(kwargs...)))
end

@static if VERSION < v"1.6"
    # verbose keyword not supported before v1.6
    # https://github.com/JuliaLang/julia/commit/68c71f577275a16fffb743b2058afdc2d635068f
    testset(a...; verbose=false, kw...) = Test.DefaultTestSet(a...; kw...)
else
    testset(a...; kw...) = Test.DefaultTestSet(a...; kw...)
end

# `Test.Error` formats the value we pass it with whatever the running Julia
# version knows how to print: a plain backtrace before v1.2, an exception stack
# from v1.2 on, which was then renamed from `catch_stack` to `current_exceptions`
# in v1.7. Note that those two boundaries are not the same version, so this
# cannot be a two way shim. Each branch passes what that version's own Test
# stdlib passes when it records an error.
@static if VERSION ≥ v"1.7"
    current_exception_stack() = Base.current_exceptions()
elseif VERSION ≥ v"1.2"
    current_exception_stack() = Base.catch_stack()
else
    current_exception_stack() = catch_backtrace()
end

@testitem "current_exception_stack" begin
    using TestItemRunner: current_exception_stack

    stack = try
        error("boom")
    catch
        current_exception_stack()
    end

    # Test.Error formats the stack when it is constructed, so building one is
    # what actually shows that we handed it the shape this Julia version wants
    err = Test.Error(:nontest_error, Expr(:tuple), ErrorException("boom"), stack, LineNumberNode(1, Symbol(@__FILE__)))

    @test err isa Test.Error
end

end
