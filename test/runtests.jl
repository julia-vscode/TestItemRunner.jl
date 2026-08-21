using TestItems, TestItemRunner

@testitem "default_imports" default_imports=true begin
    using Test
    @test true
end

@testitem "@__DIR__ resolves correctly" begin
    @test @__DIR__() == pwd()
    @test @__DIR__() == dirname(@__FILE__)
end

@testmodule TestSetup begin
    const x = 10
    getfloat() = rand()
end

@testitem "TestSetup" setup=[TestSetup] begin
    @test TestSetup.x == 10
    @test TestSetup.getfloat() isa Float64
end

@testitem "skip literal" skip=true begin
    @test false
end

@testitem "skip expression" skip=(1 + 1 == 2) begin
    @test false
end

@testitem "skip false" skip=false begin
    @test true
end

@testitem "skip with other keyword arguments" tags=[:skiptest] setup=[TestSetup] skip=true begin
    @test false
end

@testsnippet NestedRun begin
    # Several test items run a whole `run_tests` of their own over a fixture package. That
    # nested run finishes a root test set, which would otherwise be recorded into the test
    # set of the test item running it — a fixture that fails on purpose would then fail us
    # too, and every fixture would print its summary into the middle of our results.
    #
    # A test set that only collects what it is given, and that does not record itself into
    # its parent when it finishes, is what keeps the two runs apart: nothing reaches the
    # enclosing test set, nothing is printed and `run_tests` does not throw. It is the same
    # `testset=` hook the "custom testset" test item covers.
    #
    # The older approach — running the nested `run_tests` on a fresh task — relied on the
    # test set stack living in task local storage, which is no longer true: Julia 1.13
    # moved it to a `ScopedValue`, and scoped values *are* inherited by child tasks.
    mutable struct QuietTestSet <: Test.AbstractTestSet
        description::String
        results::Vector{Any}
    end

    QuietTestSet(description; verbose=false) = QuietTestSet(description, [])

    const finished_testsets = QuietTestSet[]

    Test.record(ts::QuietTestSet, result) = (push!(ts.results, result); result)
    Test.finish(ts::QuietTestSet) = (push!(finished_testsets, ts); ts)

    """
        run_nested(path; kwargs...)

    Run every test item under `path` in a run of its own and return the test sets it
    finished, keyed by description.
    """
    function run_nested(path; kwargs...)
        empty!(finished_testsets)
        TestItemRunner.run_tests(path; testset=QuietTestSet, kwargs...)

        return Dict(ts.description => ts for ts in finished_testsets)
    end

    function run_failfast_fixture(; failfast)
        log = tempname()
        touch(log)

        path = joinpath(@__DIR__, "..", "testdata", "failfast")

        try
            # Every fixture item appends its name to the log, so the log is what ran
            withenv("TESTITEMRUNNER_FAILFAST_LOG" => log) do
                run_nested(path; failfast=failfast)
            end

            return [strip(i) for i in eachline(log) if !isempty(strip(i))]
        finally
            rm(log, force=true)
        end
    end
end

@testitem "a test item's globals are released once it has run" setup=[NestedRun] begin
    finished = run_nested(joinpath(@__DIR__, "..", "testdata", "memory"))

    # The second fixture item is the assertion: it collects and then looks at what the
    # weak reference the first one parked in `Main` still points at. Its verdict is read
    # from its test set rather than repeated here, because the probe is a binding created
    # after this test item started running, which this item's world does not have to see.
    checks = finished["memory probe: check"].results

    @test length(checks) == 2
    @test all(i -> i isa Test.Pass, checks)
end

@testitem "failfast stops after the first failing test item" setup=[NestedRun] begin
    @test run_failfast_fixture(failfast=true) == ["first", "second"]
end

@testitem "without failfast every test item runs" setup=[NestedRun] begin
    @test run_failfast_fixture(failfast=false) == ["first", "second", "third"]
end

@testsnippet TreeFixture begin
    # The folder layout is the whole point of this fixture, so it is written out
    # rather than kept in `testdata`: a temporary folder has no `JuliaTestItems.toml`
    # anywhere above it, so what the walk finds depends on nothing but the layout.
    # `a` holds a file and a subfolder, while `c` and `a/b` hold a single file
    # each, which is what a folded node is made of.
    function write_tree_fixture(dir)
        for (path, name) in [
            (joinpath("a", "x.jl"), "tree x"),
            (joinpath("a", "b", "y.jl"), "tree y"),
            (joinpath("c", "z.jl"), "tree z"),
            ("top.jl", "tree top"),
        ]
            file = joinpath(dir, path)
            mkpath(dirname(file))
            write(file, "@testitem \"$name\" begin\n    @test true\nend\n")
        end
    end

    # `run_tests` finishes a root test set, which would otherwise be recorded
    # into the test set of the test item that is running it. The test set stack
    # lives in task local storage and is not inherited, so running the fixture
    # on a fresh task gives it a stack of its own.
    function run_tree_fixture()
        dir = mktempdir()
        sink = tempname()

        try
            write_tree_fixture(dir)

            # The fixture's own summary is not worth printing into the middle of
            # our results. Redirecting is what works on every version we support:
            # `Test.TESTSET_PRINT_ENABLE` became a scoped value in Julia 1.13 and
            # can no longer be assigned to.
            return open(sink, "w") do io
                redirect_stdout(io) do
                    fetch(@async TestItemRunner.run_tests(dir))
                end
            end
        finally
            rm(dir, recursive=true, force=true)
            rm(sink, force=true)
        end
    end

    subsets(ts) = [i for i in ts.results if i isa Test.DefaultTestSet]
    descriptions(ts) = [i.description for i in subsets(ts)]
end

@testitem "the summary mirrors the folder structure" setup=[TreeFixture] begin
    ts = run_tree_fixture()

    # The fixture has no Project.toml, so the root falls back to "Package"
    @test ts.description == "Package"

    # Folders come first, then files, each group alphabetical. `c` and `a/b`
    # hold a single file each and are folded into one node, with a forward slash
    # on every platform.
    @test descriptions(ts) == ["a", "c/z.jl", "top.jl"]

    # `a` holds both a subfolder and a file, so it is not folded
    a = subsets(ts)[1]
    @test descriptions(a) == ["b/y.jl", "x.jl"]

    # And the test items themselves sit below the file they are written in
    @test descriptions(subsets(a)[1]) == ["tree y"]
    @test descriptions(subsets(a)[2]) == ["tree x"]
    @test descriptions(subsets(ts)[2]) == ["tree z"]
    @test descriptions(subsets(ts)[3]) == ["tree top"]
end

@testitem "custom testset" begin
    # A test set that only collects what it is given. Not recording itself into its
    # parent when it finishes is what keeps the deliberate failure of the fixture
    # out of our own results, and it is also why `run_tests` does not throw here.
    mutable struct CollectingTestSet <: Test.AbstractTestSet
        description::String
        verbose::Bool
        results::Vector{Any}
    end

    CollectingTestSet(description; verbose=false) = CollectingTestSet(description, verbose, [])

    const collected = CollectingTestSet[]

    Test.record(ts::CollectingTestSet, result) = (push!(ts.results, result); result)
    Test.finish(ts::CollectingTestSet) = (push!(collected, ts); ts)

    path = joinpath(@__DIR__, "..", "testdata", "customtestset")

    # The test set stack lives in task local storage and is not inherited, so a
    # fresh task gives the fixture a stack of its own
    task = @async TestItemRunner.run_tests(path; testset=CollectingTestSet, verbose=true)
    wait(task)

    # All three levels of test sets, the package, the file and each test item, are
    # created from the custom test set. The package is the last one to finish.
    @test length(collected) == 6
    @test collected[end].description == "Package"
    @test collected[end].verbose
    @test any(i -> i.description == "tests.jl", collected)

    by_name = Dict(i.description => i for i in collected)

    @test length(by_name["passing"].results) == 1
    @test by_name["passing"].results[1] isa Test.Pass

    @test length(by_name["failing"].results) == 1
    @test by_name["failing"].results[1] isa Test.Fail

    # A skipped test item is recorded as broken on the test set of the test item
    @test length(by_name["skipped"].results) == 1
    @test by_name["skipped"].results[1] isa Test.Broken

    # Anything that goes wrong while preparing a test item is recorded as an error
    # on the test set of the test item
    @test length(by_name["broken setup"].results) == 1
    @test by_name["broken setup"].results[1] isa Test.Error
end

@testitem "find_test_files" begin
    using TestItemRunner: find_test_files

    path = joinpath(@__DIR__, "..", "testdata", "testitemsconfig")
    files = [replace(relpath(i, path), '\\' => '/') for i in find_test_files(path)]

    @test "included.jl" in files

    # `exclude` in JuliaTestItems.toml drops a folder from the search
    @test !("excluded/excluded.jl" in files)

    # Folders like node_modules are never descended into
    @test !("node_modules/ignored.jl" in files)

    # A nested JuliaTestItems.toml governs the settings below it, and its
    # folder is still searched
    @test "nested/nested_included.jl" in files

    # The root's `excluded/**` is anchored to the root of the fixture, so it
    # matches `excluded/` there but not `nested/excluded/` further down
    @test "nested/excluded/nested_excluded.jl" in files

    # But what the root DOES exclude stays excluded: scope is the intersection
    # over every enclosing config file, so the JuliaTestItems.toml in `nested`
    # cannot bring `nested/vetoed` back
    @test !("nested/vetoed/vetoed.jl" in files)

    @test length(files) == 3

    # The search is scoped by the folder it starts in: config files above that
    # folder are not consulted, so starting inside `nested` no longer sees the
    # `nested/vetoed/**` exclusion of the config one level up. This is also what
    # keeps `testdata/JuliaTestItems.toml`, which excludes everything, from
    # hiding the fixtures the tests point at directly.
    nested = joinpath(path, "nested")
    nested_files = [replace(relpath(i, nested), '\\' => '/') for i in find_test_files(nested)]

    @test "vetoed/vetoed.jl" in nested_files
    @test "nested_included.jl" in nested_files
    @test "excluded/nested_excluded.jl" in nested_files
    @test length(nested_files) == 3
end

dir = pwd()

@run_package_tests filter=i->endswith(i.filename, "TestItemRunner.jl") || endswith(i.filename, "testitems_config.jl") || endswith(i.filename, "runtests.jl") verbose=true

# Check that @run_package_tests didn't change the working directory
TestItemRunner.Test.@test pwd() == dir
