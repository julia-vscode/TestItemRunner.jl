@testsnippet ParseHelper begin
    import JuliaSyntax

    function parse_test_details(content)
        node = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, content, ignore_warnings=true)

        testitems = []
        testsetups = []
        testerrors = []

        TestItemDetection.find_test_detail!(node, testitems, testsetups, testerrors)

        return testitems, testsetups, testerrors
    end
end

@testitem "skip defaults to false" setup=[ParseHelper] begin
    testitems, testsetups, testerrors = parse_test_details("""@testitem "foo" begin end""")

    @test length(testitems) == 1
    @test isempty(testerrors)
    @test testitems[1].option_skip === false
end

@testitem "skip literal true" setup=[ParseHelper] begin
    testitems, testsetups, testerrors = parse_test_details("""@testitem "foo" skip=true begin end""")

    @test length(testitems) == 1
    @test isempty(testerrors)
    @test testitems[1].option_skip === true
end

@testitem "skip literal false" setup=[ParseHelper] begin
    testitems, testsetups, testerrors = parse_test_details("""@testitem "foo" skip=false begin end""")

    @test length(testitems) == 1
    @test isempty(testerrors)
    @test testitems[1].option_skip === false
end

@testitem "skip expression is returned as a source range" setup=[ParseHelper] begin
    content = """@testitem "foo" skip=(VERSION < v"1.11") begin end"""

    testitems, testsetups, testerrors = parse_test_details(content)

    @test length(testitems) == 1
    @test isempty(testerrors)
    @test testitems[1].option_skip isa UnitRange{Int}
    # Parentheses are trivia to JuliaSyntax, so the range covers the expression itself.
    @test content[testitems[1].option_skip] == "VERSION < v\"1.11\""
end

@testitem "skip call expression is returned as a source range" setup=[ParseHelper] begin
    content = """@testitem "foo" skip=Sys.iswindows() begin end"""

    testitems, testsetups, testerrors = parse_test_details(content)

    @test length(testitems) == 1
    @test content[testitems[1].option_skip] == "Sys.iswindows()"
end

@testitem "duplicate skip keyword argument" setup=[ParseHelper] begin
    testitems, testsetups, testerrors = parse_test_details("""@testitem "foo" skip=true skip=false begin end""")

    @test isempty(testitems)
    @test length(testerrors) == 1
    @test testerrors[1].message == "The keyword argument skip cannot be specified more than once."
end

@testitem "skip combines with the other keyword arguments" setup=[ParseHelper] begin
    testitems, testsetups, testerrors = parse_test_details(
        """@testitem "foo" tags=[:a] default_imports=false setup=[Bar] skip=true begin end"""
    )

    @test length(testitems) == 1
    @test isempty(testerrors)

    ti = testitems[1]

    @test ti.option_tags == [:a]
    @test ti.option_default_imports == false
    @test ti.option_setup == [:Bar]
    @test ti.option_skip === true
end

@testitem "unknown keyword arguments are still rejected" setup=[ParseHelper] begin
    testitems, testsetups, testerrors = parse_test_details("""@testitem "foo" bar=true begin end""")

    @test isempty(testitems)
    @test length(testerrors) == 1
    @test testerrors[1].message == "Unknown keyword argument."
end
