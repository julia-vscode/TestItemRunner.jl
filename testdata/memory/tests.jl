# Fixture for the test that a test item's globals are released once it finishes.
#
# The two items are in one file and in this order, because `run_tests` iterates
# files in `Dict` order but test items within a file in source order.
#
# The probe is parked in `Main` rather than in the item's own module precisely
# because `Main` is what the teardown does not touch.

@testitem "memory probe: bind" begin
    leaked = zeros(UInt8, 8_000_000)
    Core.eval(Main, :(TESTITEMRUNNER_MEMORY_PROBE = $(WeakRef(leaked))))
    @test length(leaked) == 8_000_000
end

@testitem "memory probe: check" begin
    GC.gc(true)
    GC.gc(true)

    @test isdefined(Main, :TESTITEMRUNNER_MEMORY_PROBE)
    @test Main.TESTITEMRUNNER_MEMORY_PROBE.value === nothing
end
