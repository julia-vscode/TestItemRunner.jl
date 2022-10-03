module TestItemRunner

include("../packages/Tokenize/src/Tokenize.jl")

module CSTParser
    using ..Tokenize
    import ..Tokenize.Tokens
    import ..Tokenize.Tokens: RawToken, AbstractToken, iskeyword, isliteral, isoperator, untokenize
    import ..Tokenize.Lexers: Lexer, peekchar, iswhitespace, readchar, emit, emit_error,  accept_batch, eof

    include("../packages/CSTParser/src/packagedef.jl")
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

    return line, column
end

@testitem "compute_line_column" begin
    content = "abc\ndef\nghi"

    @test TestItemRunner.compute_line_column(content, 1) == (1, 1)
    @test TestItemRunner.compute_line_column(content, 2) == (1, 2)
    @test TestItemRunner.compute_line_column(content, 3) == (1, 3)
    @test TestItemRunner.compute_line_column(content, 5) == (2, 1)
    @test TestItemRunner.compute_line_column(content, 6) == (2, 2)
    @test TestItemRunner.compute_line_column(content, 7) == (2, 3)
    @test TestItemRunner.compute_line_column(content, 9) == (3, 1)
    @test TestItemRunner.compute_line_column(content, 10) == (3, 2)
    @test TestItemRunner.compute_line_column(content, 11) == (3, 3)
end

function find_test_items_detail!(filename, content, node, testitems)
    node isa EXPR || return

    if node.head == :macrocall && length(node.args) == 4 && CSTParser.valof(node.args[1]) == "@testitem"

        pos = get_file_loc(node.args[4])[2]

        loc = pos:pos+node.args[4].span

        line, column = compute_line_column(content, pos)

        push!(testitems, (filename=filename, code=content[loc], name=CSTParser.valof(node.args[3]), line=line - 1, column=column))
    elseif node.head == :module && length(node.args) >= 3 && node.args[3] isa EXPR && node.args[3].head == :block
        for i in node.args[3].args
            find_test_items_detail!(filename, content, i, testitems)
        end
    end
end

function run_testitem(filepath, use_default_usings, package_name, original_code, line, column)
    mod = Core.eval(Main, :(module Testmodule end))

    if use_default_usings
        Core.eval(mod, :(using Test))

        if package_name!=""
            Core.eval(mod, :(using $(Symbol(package_name))))
        end
    end

    code_without_begin_end = strip(original_code)[6:end-3]
    code = string('\n'^line, ' '^column, code_without_begin_end)



    withpath(filepath) do
        Base.invokelatest(include_string, mod, code, filepath)
    end
end

function run_tests(path)
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
        for i in cst.args
            find_test_items_detail!(file, content, i, testitems_for_file)
        end

        if length(testitems_for_file) > 0
            testitems[file] = testitems_for_file
        end
    end

    # Run testitems
    Test.push_testset(Test.DefaultTestSet("Package"))
    for (file, testitems) in pairs(testitems)
        Test.push_testset(Test.DefaultTestSet(relpath(file, path)))
        for testitem in testitems
            Test.push_testset(Test.DefaultTestSet(testitem.name))
            run_testitem(testitem.filename, true, package_name, testitem.code, testitem.line, testitem.column)
            Test.finish(Test.pop_testset())
        end
        Test.finish(Test.pop_testset())
    end
    ts = Test.pop_testset()
    Test.finish(ts)
end

macro run_package_tests()
    :(run_tests(joinpath($(dirname(string(__source__.file))), "..")))
end

end
