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
    using ..JuliaSyntax: @K_str, kind, children, haschildren, first_byte, last_byte, SyntaxNode

    include("../packages/TestItemDetection/src/packagedef.jl")
end

import Test, TestItems, TOML
using TestItems: @testitem

include("vendored_code.jl")

export @run_package_tests, @testitem

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
    content = "abc\ndef\nghi"

    @test TestItemRunner.compute_line_column(content, 1) == (line=1, column=1)
    @test TestItemRunner.compute_line_column(content, 2) == (line=1, column=2)
    @test TestItemRunner.compute_line_column(content, 3) == (line=1, column=3)
    @test TestItemRunner.compute_line_column(content, 5) == (line=2, column=1)
    @test TestItemRunner.compute_line_column(content, 6) == (line=2, column=2)
    @test TestItemRunner.compute_line_column(content, 7) == (line=2, column=3)
    @test TestItemRunner.compute_line_column(content, 9) == (line=3, column=1)
    @test TestItemRunner.compute_line_column(content, 10) == (line=3, column=2)
    @test TestItemRunner.compute_line_column(content, 11) == (line=3, column=3)
end

struct TestSetupModuleSet
    setupmodule::Module
    modules::Set{Symbol}
end

function ensure_evaled(test_setup_module_set, filename, code, name, line, column, working_dir)
    if !(name in test_setup_module_set.modules)
        mod = Core.eval(test_setup_module_set.setupmodule, :(module $(Symbol(name)) end))
        code = string('\n'^line, ' '^column, code)
        cd(working_dir)
        withpath(filename) do
            Base.invokelatest(include_string, mod, code, filename)
        end
    end
    push!(test_setup_module_set.modules, name)
    return
end

function run_testitem(filepath, use_default_usings, setups, package_name, original_code, line, column, test_setup_module_set, testsetups)
    working_dir = dirname(filepath)
    cd(working_dir)
    
    mod = Core.eval(Main, :(module $(gensym()) end))

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
            withpath(setup_details.filename) do
                Base.invokelatest(include_string, mod, snippet_code, setup_details.filename)
            end
        else
            error("Unknown test setup")
        end
    end

    code = string('\n'^(line-1), ' '^(column-1), original_code)

    withpath(filepath) do
        Base.invokelatest(include_string, mod, code, filepath)
    end
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

    # Find all Julia files in this folder and sub folders
    julia_files = String[]
    for (root, _, files) in walkdir(path)
        for file in files
            if endswith(lowercase(file), ".jl")
                push!(julia_files, normpath(joinpath(root, file)))
            end
        end

    end

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
            testitems[file] = [(filename=file, code=content[i.code_range], name=i.name, option_tags=i.option_tags, option_default_imports=i.option_default_imports, option_setup=i.option_setup, compute_line_column(content, i.code_range.start)...) for i in testitems_for_file]
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
    Test.push_testset(testset("Package"; verbose=verbose))
    for (file, testitems) in pairs(testitems)
        Test.push_testset(testset(relpath(file, path); verbose=verbose))
        for testitem in testitems
            snippets_to_run = []
            if !isempty(testitem.option_setup)
                for setup in testitem.option_setup
                    key = setup
                    if haskey(testsetups, key)
                        testsetup = testsetups[key]
                        if testsetup.kind==:module
                            working_dir = dirname(file)
                            ensure_evaled(test_setup_module_set, testsetup.filename, testsetup.code, testsetup.name, testsetup.line, testsetup.column, working_dir)
                        elseif testsetup.kind==:snippet
                            push!(snippets_to_run, testsetup)
                        else
                            error("Unknown setup type")
                        end
                    else
                        error("Test setup $(setup) is not defined.")
                    end
                end
            end
            Test.push_testset(testset(testitem.name; verbose=verbose))
            run_testitem(testitem.filename, testitem.option_default_imports, testitem.option_setup, package_name, testitem.code, testitem.line, testitem.column, test_setup_module_set, testsetups)
            Test.finish(Test.pop_testset())
        end
        Test.finish(Test.pop_testset())
    end
    ts = Test.pop_testset()
    Test.finish(ts)
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

end
