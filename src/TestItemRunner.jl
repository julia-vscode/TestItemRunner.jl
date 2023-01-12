module TestItemRunner

include("../packages/Tokenize/src/Tokenize.jl")

module CSTParser
    using ..Tokenize
    import ..Tokenize.Tokens
    import ..Tokenize.Tokens: RawToken, AbstractToken, iskeyword, isliteral, isoperator, untokenize
    import ..Tokenize.Lexers: Lexer, peekchar, iswhitespace, readchar, emit, emit_error,  accept_batch, eof

    include("../packages/CSTParser/src/packagedef.jl")
end

module TestItemDetection
    import ..CSTParser
    using ..CSTParser: EXPR

    include("../packages/TestItemDetection/src/packagedef.jl")
end

import .CSTParser, Test, TestItems, TOML
using .CSTParser: EXPR, parentof, headof
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

function run_testitem(filepath, use_default_usings, setup, package_name, original_code, line, column)
    mod = Core.eval(Main, :(module $(gensym()) end))

    if use_default_usings
        Core.eval(mod, :(using Test))

        if package_name!=""
            Core.eval(mod, :(using $(Symbol(package_name))))
        end
    end

    for m in setup
        Core.eval(mod, Expr(:using, Expr(:., :., :., m)))
    end

    code = string('\n'^line, ' '^column, original_code)

    withpath(filepath) do
        Base.invokelatest(include_string, mod, code, filepath)
    end
end

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

    # Find all @testitems
    testitems = Dict{String,Vector}()
    for file in julia_files
        content = read(file, String)
        cst = CSTParser.parse(content, true)

        testitems_for_file = []
        errors_for_file = []
        for i in cst.args
            TestItemDetection.find_test_items_detail!(i, testitems_for_file, errors_for_file)
        end

        if length(errors_for_file) > 0
            error("There is an error in your test item definition, we are aborting.")
        end

        if length(testitems_for_file) > 0
            testitems[file] = [(filename=file, code=content[i.code_range], name=i.name, option_tags=i.option_tags, option_default_imports=i.option_default_imports, option_setup=i.option_setup, compute_line_column(content, i.code_range.start)...) for i in testitems_for_file]
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
    Test.push_testset(testset("Package"; verbose=verbose))
    for (file, testitems) in pairs(testitems)
        Test.push_testset(testset(relpath(file, path); verbose=verbose))
        for testitem in testitems
            Test.push_testset(testset(testitem.name; verbose=verbose))
            run_testitem(testitem.filename, testitem.option_default_imports, testitem.option_setup, package_name, testitem.code, testitem.line, testitem.column)
            Test.finish(Test.pop_testset())
        end
        Test.finish(Test.pop_testset())
    end
    ts = Test.pop_testset()
    Test.finish(ts)
end

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
