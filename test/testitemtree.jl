
@testitem "insert_node!" begin
    using TestItemRunner: TestItemTree, insert_node!
    tree = TestItemTree("ROOT", pwd())

    # Relative path
    insert_node!(tree, joinpath("a", "b", "file1.jl"))
    @test tree.nodes["a"].nodes["b"].nodes["file1.jl"].path == joinpath(pwd(), "a", "b", "file1.jl")

    # Absolute path
    insert_node!(tree, joinpath(pwd(), "a", "b", "file2.jl"))
    @test tree.nodes["a"].nodes["b"].nodes["file2.jl"].path == joinpath(pwd(), "a", "b", "file2.jl")
end

@testitem "simplify!" begin
    using TestItemRunner: TestItemTree, insert_node!, simplify!

    tree = TestItemTree("ROOT", pwd())
    insert_node!(tree, joinpath("a", "file1.jl"))
    insert_node!(tree, joinpath("a", "file2.jl"))
    insert_node!(tree, joinpath("b", "file.jl"))

    @test tree.nodes["a"].nodes["file1.jl"].path == joinpath(pwd(), "a", "file1.jl")
    @test tree.nodes["b"].nodes["file.jl"].path  == joinpath(pwd(), "b", "file.jl")

    simplify!(tree)
    @test tree.nodes["b"].path  == joinpath(pwd(), "b", "file.jl")
    @test tree.nodes["b"].name  == "b/file.jl"
end
