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
