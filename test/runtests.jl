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

function myfilter(i)
    for fname in ("TestItemRunner.jl", "runtests.jl", "testitemtree.jl")
        endswith(i.filename, fname) && return true
    end
    return false
end
@run_package_tests filter=myfilter verbose=true
