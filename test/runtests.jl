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

@run_package_tests filter=i->endswith(i.filename, "TestItemRunner.jl") || endswith(i.filename, "runtests.jl") verbose=true