# Test items used by the "custom testset" test item in `test/runtests.jl`. They are
# never run by this package's own `@run_package_tests`, whose filter only accepts the
# files of the package itself.

@testitem "passing" begin
    @test true
end

@testitem "failing" begin
    @test false
end

@testitem "skipped" skip=true begin
    @test false
end

@testitem "broken setup" setup=[NotDefinedAnywhere] begin
    @test true
end
