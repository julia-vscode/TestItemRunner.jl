# Fixture for the `failfast` tests. The three test items live in one file, and
# in this order, because test items within a file run in source order — so this
# is the only way to know which item runs second.
#
# Every item appends its name to the file named by `TESTITEMRUNNER_FAILFAST_LOG`,
# which is how the test sees what actually ran.

@testitem "failfast first" begin
    open(ENV["TESTITEMRUNNER_FAILFAST_LOG"], "a") do io
        println(io, "first")
    end

    @test true
end

@testitem "failfast second" begin
    open(ENV["TESTITEMRUNNER_FAILFAST_LOG"], "a") do io
        println(io, "second")
    end

    @test false
end

@testitem "failfast third" begin
    open(ENV["TESTITEMRUNNER_FAILFAST_LOG"], "a") do io
        println(io, "third")
    end

    @test true
end
