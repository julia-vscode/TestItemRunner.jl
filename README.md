# TestItemRunner.jl

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
![](https://github.com/julia-vscode/TestItemRunner.jl/workflows/Run%20tests/badge.svg)
[![codecov](https://codecov.io/gh/julia-vscode/TestItemRunner.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/julia-vscode/TestItemRunner.jl)

## Overview

This package runs `@testitem` tests.

## Usage

### Writing tests

In the framework of this package, you write your tests inside `@testitem` macros. Each test item is the smallest unit of code that can be individually run and must be entirely self contained. In fact, when a `@testitem` is executed, all the code in the test item will be placed into a new Julia `module` and then this new module will be run. A typical `@testitem` might look like this:

```julia
@testitem "First tests" begin
    x = foo("bar")

    @test length(x)==3
    @test x == "bar"
end
```

Note how the first argument to the `@testitem` macro is a name for the test item, followed by a `begin end` block that contains the actual test code. Note that you do not need to load the `Test` package nor the package you are testing, both of these are automatically loaded into the `@testitem`. Inside the test code, we first  run some code from our package and finally use the standard base library `@test` macros to test whether our function returns the correct results.

You can put `@testitem` macros into any *.jl Julia file in your package, even next to the functions that you are testing, or more traditionally into Julia files in your `test` folder. 

#### Writing test items inside the regular package code

If you want to put your test code inside the code files of your actual package, you should add the [TestItems.jl](https://github.com/julia-vscode/TestItems.jl) package as a regular dependency of your package. `TestItems` exports the `@testitem` macro (and nothing else), so your main package file might look like this:

```julia
module MyPackage

using TestItems

function foo(x)
    return x*x
end

@testitem "Test for foo" begin
    x = foo("bar")

    @test x == "barbar"
end

end
```

Adding tests like this to your regular package should have a minimal runtime overhead for your package: The `TestItems` package only defines the `@testitem` macro, and the `@testitem` macro always returns `nothing`, so that all test code is essentially removed from your package when a user loads it.

#### Writing test items in test files

You can also place `@testitem`s in test files inside your `test` folder (or any folder in your package). These test files do _not_ need to be included in the `test/runtests.jl` file, they can just be standalone files. A typical test file `test/test_foo.jl` might look like this:

```julia
@testitem "Another test for foo" begin
    x = foo("bar")

    @test x != "bar"
end
```

Note that in this case you don't even have to use the `TestItems` package in this file. Because this new file `test/test_foo.jl` is never going to be run as an entire file, we can skip the `using TestItems` part.

#### Test item options

You can set specific options for individual `@testitem`s. At the moment the framework supports two, namely a tag system and an option to control default imports.

##### Tags

You can assign arbitrary tags to a `@testitem`. A tag must be a `Symbol`, and you can assign multiple tags to each `@testitem`. Tags can be used to more easily select subsets of `@testitem`s for execution. Here is an example that assigns the `:skipci` tag to a `@testitem`:

```julia
@testitem "Another test for foo" tags=[:skipci] begin
    x = foo("bar")

    @test x != "bar"
end
```

##### Default imports

When you write a `@testitem`, by default the package being tested and the `Test` package are imported via an invisible `using` statement. In some cases this might not be desirable, so one can control this behavior on a per `@testitem` level via the `default_imports` option, which accepts a `Bool` value. To disable these default imports you, you would write:

```julia
@testitem "Another test for foo" default_imports=false begin
    using MyPackage, Test

    x = foo("bar")

    @test x != "bar"
end
```

Note how we now need to add the line `using MyPackage, Test` manually to our `@testitem` so that we have access to the `foo` function and `@test` macro.

### Running tests

At the moment there are two ways to run `@testitem`s: with the integrated test UI in the Julia VS Code extension, or with this package TestItemRunner.jl. In both cases test item detection is based on syntactic analysis, i.e. no code from your package is run to detect test items. Both execution engines will instead look at all *.jl files in your package folder, identify all `@testitem` calls and then provide ways to run them.

#### Integrating with the base test system

If you want your tests to run when a user calls the regular base test functionality, or have you your tests run during CI runs, you can simply add this package TestItemRunner.jl as a test dependency to your package, and then add this content as your `test/runtests.jl` file:

```julia
using TestItemRunner

@run_package_tests
```

Sometimes it is convenient to not run all detected `@testitem`s but only a subset. You can specify a custom filter function to achieve this. Your filter function will be called for each detected `@testitem`, and must return a `Bool` value indicating whether this particular `@testitem` should be executed or not. For example, here is an example that will only run `@testitem`s that don't have the `:skipci` tag assigned:

```julia
using TestItemRunner

@run_package_tests filter=ti->!(:skipci in ti.tags)
```

The value that is passed to your custom filter function has three fields that you can use to extract information about a test item:
- `name`: The full name of the `@testitem`, as a `String`.
- `filename`: The full absolute filename of the file in which the `@testitem` is defined.
- `tags`: A `Vector{Symbol}` with all the tags that you defined for this particular `@testitem`.

If you want to print a summary of test results which shows all the `@testitems`, then you can pass `verbose=true`:

```julia
using TestItemRunner

@run_package_tests verbose=true
```
