using TestItems, TestItemRunner

@testitem "default_imports" default_imports=true begin
    using Test
    @test true
end

@testsetup module TestSetup
    const x = 10
    getfloat() = rand()
end

@testitem "TestSetup" setup=[TestSetup] begin
    @test TestSetup.x == 10
    @test TestSetup.getfloat() isa Float64
end

@testsetup module CrossTestSetup
    using Test
    using ..TestSetup: x, getfloat
    function cross_test()
        @test x == 10
        @test getfloat() isa Float64
    end
end

@testitem "CrossTestSetup" setup=[TestSetup, CrossTestSetup] begin
    using .CrossTestSetup: cross_test
    cross_test()
end

@run_package_tests filter=i->endswith(i.filename, "TestItemRunner.jl") || endswith(i.filename, "runtests.jl") verbose=true
