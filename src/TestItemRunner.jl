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
    end

    return
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
searched, see [`testitems_selected`](@ref). Config files in the directories
*above* `path` count too, so that searching a subdirectory directly honours the
same exclusions as searching the whole project.
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

    # Scope is the intersection over every enclosing config file, so the ones
    # above `path` matter as much as the ones inside it — otherwise running the
    # tests of a vendored subpackage directly would see a different set of test
    # items than the language server shows for the whole project.
    append!(config_files, _enclosing_config_files(path))

    isempty(config_files) && return julia_files

    configs = Dict{String,PathFilter}(i => parse_testitems_config(i) for i in config_files)

    return Base.filter(i -> testitems_selected(configs, i), julia_files)
end

# Every `JuliaTestItems.toml` in a strict ancestor directory of `dir`, walking up
# to the filesystem root.
function _enclosing_config_files(dir)
    res = String[]

    current = dirname(dir)
    while true
        candidate = joinpath(current, "JuliaTestItems.toml")
        isfile(candidate) && push!(res, normpath(candidate))

        parent = dirname(current)
        parent == current && break
        current = parent
    end

    return res
end

"""
    run_tests(path; filter=nothing, verbose=false)

Run all test items in a directory and its subdirectories.

# Arguments
- `path`: The path to the directory containing the tests.
- `filter`: A filter function to apply to the test items.
- `verbose`: Whether to run the tests in verbose mode.
"""
function run_tests(path; filter=nothing, verbose=false)
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

    # Run testitems
    test_setup_module = Core.eval(Main, :(module $(gensym()) end))
    test_setup_module_set = TestSetupModuleSet(test_setup_module, Set{Symbol}())

    @static if VERSION ≤ v"1.13-"
        Test.push_testset(testset("Package"; verbose=verbose))
        try
            for (file, testitems) in pairs(testitems)
                Test.push_testset(testset(relpath(file, path); verbose=verbose))
                try
                    for testitem in testitems
                        Test.push_testset(testset(testitem.name; verbose=verbose))
                        ts = Test.get_testset()
                        try
                            run_testitem_in_testset(ts, testitem, package_name, test_setup_module_set, testsetups)
                        finally
                            Test.finish(Test.pop_testset())
                        end
                    end
                finally
                    Test.finish(Test.pop_testset())
                end
            end
        finally
            ts = Test.pop_testset()
            # Outer testset generates report that needs to integrate results from nested (custom) testsets
            Base.invokelatest(Test.finish, ts)
        end
    else
        ts_1 = testset("Package"; verbose=verbose)
        Test.@with_testset ts_1 begin
            for (file, testitems) in pairs(testitems)
                ts_2 = testset(relpath(file, path); verbose=verbose)
                Test.@with_testset ts_2 begin
                    for testitem in testitems
                        ts_3 = testset(testitem.name; verbose=verbose)
                        Test.@with_testset ts_3 begin
                            run_testitem_in_testset(ts_3, testitem, package_name, test_setup_module_set, testsetups)
                        end
                        Test.finish(ts_3)
                    end
                end
                Test.finish(ts_2)
            end
        end
        # Outer testset generates report that needs to integrate results from nested (custom) testsets
        Base.invokelatest(Test.finish, ts_1)
    end
end

"""
    @run_package_tests(ex...)

Run all test items in a package, using optional filter and verbosity arguments.

# Usage
```julia
@run_package_tests filter=<filter_function>, verbose=<bool>
```

```julia
@run_package_tests filter=ti->!(:skipci in ti.tags)
```

# Arguments
- `filter`: An optional filter function to apply to the test items.
- `verbose`: An optional argument to specify verbosity.
"""
macro run_package_tests(ex...)
    kwargs = []

    for i in ex
        if i isa Expr && i.head==:(=) && length(i.args)==2 && i.args[1] in (:filter, :verbose)
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
