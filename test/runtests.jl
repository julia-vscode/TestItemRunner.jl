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

@testitem "a test item's globals are released once it has run" begin
    # `run_tests` finishes a root test set, which would otherwise be recorded into the
    # test set of the test item running it. The test set stack lives in task local
    # storage and is not inherited, so a fresh task gives the fixture a stack of its own.
    path = joinpath(@__DIR__, "..", "testdata", "memory")

    printing = Test.TESTSET_PRINT_ENABLE[]
    Test.TESTSET_PRINT_ENABLE[] = false
    try
        task = @async try
            TestItemRunner.run_tests(path)
        catch err
            err
        end
        wait(task)
    finally
        Test.TESTSET_PRINT_ENABLE[] = printing
    end

    # The second fixture item is the assertion: it collects and then looks at what the
    # weak reference the first one parked in `Main` still points at
    @test isdefined(Main, :TESTITEMRUNNER_MEMORY_PROBE)
    @test Main.TESTITEMRUNNER_MEMORY_PROBE.value === nothing
end

@testsnippet FailfastFixture begin
    # `run_tests` finishes a root test set, which throws when anything failed,
    # and which would otherwise be recorded into the test set of the test item
    # that is running it. The test set stack lives in task local storage and is
    # not inherited, so running the fixture on a fresh task gives it a stack of
    # its own and keeps its deliberate failure out of our own results.
    function run_failfast_fixture(; failfast)
        log = tempname()
        touch(log)

        path = joinpath(@__DIR__, "..", "testdata", "failfast")

        # The fixture fails on purpose, so its summary and its failure report are
        # silenced rather than printed into the middle of our own results
        printing = Test.TESTSET_PRINT_ENABLE[]
        Test.TESTSET_PRINT_ENABLE[] = false

        try
            withenv("TESTITEMRUNNER_FAILFAST_LOG" => log) do
                task = @async try
                    TestItemRunner.run_tests(path; failfast=failfast)
                catch err
                    err
                end
                wait(task)
            end

            return [strip(i) for i in eachline(log) if !isempty(strip(i))]
        finally
            Test.TESTSET_PRINT_ENABLE[] = printing
            rm(log, force=true)
        end
    end
end

@testitem "failfast stops after the first failing test item" setup=[FailfastFixture] begin
    @test run_failfast_fixture(failfast=true) == ["first", "second"]
end

@testitem "without failfast every test item runs" setup=[FailfastFixture] begin
    @test run_failfast_fixture(failfast=false) == ["first", "second", "third"]
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
