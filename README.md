# TestItemRunner.jl

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
![](https://github.com/julia-vscode/TestItemRunner.jl/workflows/Run%20tests/badge.svg)
[![codecov](https://codecov.io/gh/julia-vscode/TestItemRunner.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/julia-vscode/TestItemRunner.jl)

## Overview

This package runs `@testitem` tests. You can learn more over at the [documentation](https://www.julia-vscode.org/docs/stable/userguide/testitems/) for the entire test item ecosystem. Note that while the documentation is hosted as part of the Julia VS Code extension, the test item framework is not a VS Code extension specific technology and can be used entirely without VS Code.

## Working on this package

Note that the content of the `packages` folder should never be manually edited. All subfolders there are git subtrees and one should only use the provided Julia script `scripts/update_vendored_packages.jl` to update them from upstream.

