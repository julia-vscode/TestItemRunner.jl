@testitem "@testitem macro missing all args" begin
    import CSTParser

    code = CSTParser.parse("""@testitem
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="Your @testitem is missing a name and code block.", range=1:9)
end

@testitem "Wrong type for name" begin
    import CSTParser

    code = CSTParser.parse("""@testitem :foo
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="Your @testitem must have a first argument that is of type String for the name.", range=1:14)
end

@testitem "Code block missing" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo"
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="Your @testitem is missing a code block argument.", range=1:15)
end

@testitem "Final arg not a code block" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" 3
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The final argument of a @testitem must be a begin end block.", range=1:17)
end

@testitem "None kw arg" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" bar begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The arguments to a @testitem must be in keyword format.", range=1:29)
end

@testitem "Duplicate kw arg" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" default_imports=true default_imports=false begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The keyword argument default_imports cannot be specified more than once.", range=1:68)
end

@testitem "Incomplete kw arg" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" default_imports= begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The final argument of a @testitem must be a begin end block.", range=1:42)
end

@testitem "Wrong default_imports type kw arg" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" default_imports=4 begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The keyword argument default_imports only accepts bool values.", range=1:43)
end

@testitem "non vector arg for tags kw" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" tags=4 begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The keyword argument tags only accepts a vector of symbols.", range=1:32)
end

@testitem "Wrong types in tags kw arg" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" tags=[4, 8] begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="The keyword argument tags only accepts a vector of symbols.", range=1:37)
end

@testitem "Unknown keyword arg" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" bar=true begin end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 0
    @test length(errors) == 1

    @test errors[1] == (error="Unknown keyword argument.", range=1:34)
end

@testitem "All parts correctly there" begin
    import CSTParser

    code = CSTParser.parse("""@testitem "foo" tags=[:a, :b] setup=[FooSetup] default_imports=true begin println() end
    """)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_items) == 1
    @test length(errors) == 0

    @test test_items[1] == (name="foo", range=1:87, code_range=74:84, option_default_imports=true, option_tags=[:a, :b], option_setup=Symbol[:FooSetup])
end

@testitem "@testsetup macro missing module arg" begin
    import CSTParser

    src = """@testsetup
    """
    code = CSTParser.parse(src)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_setups) == 0
    @test length(errors) == 1

    @test errors[1] == (error="Your `@testsetup` is missing a `module ... end` block.", range=1:length(src)-1)
end

@testitem "@testsetup macro extra args" begin
    import CSTParser

    src = """@testsetup "Foo" module end"""
    code = CSTParser.parse(src)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_setups) == 0
    @test length(errors) == 1

    @test errors[1] == (error="Your `@testsetup` must have a single `module ... end` argument.", range=1:length(src))
end

@testitem "@testsetup all correct" begin
    import CSTParser

    src = """@testsetup module Foo
        const BAR = 1
        qux() = 2
    end
    """
    code = CSTParser.parse(src)

    test_items = []
    test_setups = []
    errors = []
    TestItemDetection.find_test_detail!(code, test_items, test_setups, errors)

    @test length(test_setups) == 1
    @test length(errors) == 0

    @test test_setups[1] == (
        name="Foo",
        range=1:length(src)-1,
        code_range=(length("@testsetup module Foo") + 1):(length(src) - 4)
    )
end
