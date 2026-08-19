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

@testitem "find_test_files" begin
    using TestItemRunner: find_test_files

    path = joinpath(@__DIR__, "..", "testdata", "testitemsconfig")
    files = [replace(relpath(i, path), '\\' => '/') for i in find_test_files(path)]

    @test "included.jl" in files

    # `exclude` in JuliaTestItems.toml drops a folder from the search
    @test !("excluded/excluded.jl" in files)

    # Folders like node_modules are never descended into
    @test !("node_modules/ignored.jl" in files)

    # The nearest JuliaTestItems.toml replaces the one above it wholesale, so
    # the `excluded/**` exclusion does not apply below `nested`
    @test "nested/nested_included.jl" in files
    @test "nested/excluded/nested_excluded.jl" in files

    @test length(files) == 3
end

dir = pwd()

@run_package_tests filter=i->endswith(i.filename, "TestItemRunner.jl") || endswith(i.filename, "testitems_config.jl") || endswith(i.filename, "runtests.jl") verbose=true

# Check that @run_package_tests didn't change the working directory
TestItemRunner.Test.@test pwd() == dir
