using TestItemRunner

@run_package_tests filter=i->endswith(i.filename, "TestItemRunner.jl")
