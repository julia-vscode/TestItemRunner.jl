# TestItemRunner.jl

[![Project Status: WIP – Initial development is in progress, but there has not yet been a stable, usable release suitable for the public.](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
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

### Running tests

At the moment there are two ways to run `@testitem`s: with the upcoming integrated test UI in the Julia VS Code extension, or with this package TestItemRunner.jl. In both cases test item detection is based on syntactic analysis, i.e. no code from your package is run to detect test items. Both execution engines will instead look at all *.jl files in your package folder, identify all `@testitem` calls and then provide ways to run them.

#### Integrating with the base test system

If you want your tests to run when a user calls the regular base test functionality, or have you your tests run during CI runs, you can simplye add this package TestItemRunner.jl as a test dependency to your package, and then add this content as your `test/runtests.jl` file:

```julia
using TestItemRunner

@run_package_tests
```
