include("vendored_code.jl")

function find_test_detail!(node, testitems, testsetups, errors)
    node isa EXPR || return

    if node.head == :macrocall && length(node.args)>0 && CSTParser.valof(node.args[1]) == "@testitem"
        pos = 1 + get_file_loc(node)[2]
        range = pos:pos+node.span-1

        # filter out line nodes
        child_nodes = filter(i->!(isa(i, EXPR) && i.head==:NOTHING && i.args===nothing), node.args)

        # Check for various syntax errors
        if length(child_nodes)==1
            push!(errors, (error="Your @testitem is missing a name and code block.", range=range))
            return
        elseif length(child_nodes)>1 && !(child_nodes[2] isa EXPR && child_nodes[2].head==:STRING)
            push!(errors, (error="Your @testitem must have a first argument that is of type String for the name.", range=range))
            return
        elseif length(child_nodes)==2
            push!(errors, (error="Your @testitem is missing a code block argument.", range=range))
            return
        elseif !(child_nodes[end] isa EXPR && child_nodes[end].head in (:block, :let))
            push!(errors, (error="The final argument of a @testitem must be a begin end block or let end block.", range=range))
            return
        else
            option_tags = nothing
            option_default_imports = nothing
            option_setup = nothing

            # Now check our keyword args
            for i in child_nodes[3:end-1]
                if !(i isa EXPR && i.head isa EXPR && i.head.head==:OPERATOR && CSTParser.valof(i.head)=="=")
                    push!(errors, (error="The arguments to a @testitem must be in keyword format.", range=range))
                    return
                elseif !(length(i.args)==2)
                    error("This code path should not be possible.")
                elseif CSTParser.valof(i.args[1])=="tags"
                    if option_tags!==nothing
                        push!(errors, (error="The keyword argument tags cannot be specified more than once.", range=range))
                        return
                    end

                    if !(i.args[2].head == :vect)
                        push!(errors, (error="The keyword argument tags only accepts a vector of symbols.", range=range))
                        return
                    end

                    option_tags = Symbol[]

                    for j in i.args[2].args
                        if !(j isa EXPR && j.head==:quotenode && length(j.args)==1 && j.args[1] isa EXPR && j.args[1].head==:IDENTIFIER)
                            push!(errors, (error="The keyword argument tags only accepts a vector of symbols.", range=range))
                            return
                        end

                        push!(option_tags, Symbol(CSTParser.valof(j.args[1])))
                    end
                elseif CSTParser.valof(i.args[1])=="default_imports"
                    if option_default_imports!==nothing
                        push!(errors, (error="The keyword argument default_imports cannot be specified more than once.", range=range))
                        return
                    end

                    if !(CSTParser.valof(i.args[2]) in ("true", "false"))
                        push!(errors, (error="The keyword argument default_imports only accepts bool values.", range=range))
                        return
                    end

                    option_default_imports = parse(Bool, CSTParser.valof(i.args[2]))
                elseif CSTParser.valof(i.args[1])=="setup"
                    if option_setup!==nothing
                        push!(errors, (error="The keyword argument setup cannot be specified more than once.", range=range))
                        return
                    end

                    if !(i.args[2].head == :vect)
                        push!(errors, (error="The keyword argument `setup` only accepts a vector of `@testsetup module` names.", range=range))
                        return
                    end
                    option_setup = Symbol[]

                    for j in i.args[2].args
                        if !(j isa EXPR && j.head==:IDENTIFIER)
                            push!(errors, (error="The keyword argument `setup` only accepts a vector of `@testsetup module` names.", range=range))
                            return
                        end

                        push!(option_setup, Symbol(CSTParser.valof(j)))
                    end
                else
                    push!(errors, (error="Unknown keyword argument.", range=range))
                    return
                end
            end

            if option_tags===nothing
                option_tags = Symbol[]
            end

            if option_default_imports===nothing
                option_default_imports = true
            end

            if option_setup===nothing
                option_setup = Symbol[]
            end

            # TODO + 1 here is from the space before the begin end block. We might have to detect that,
            # not sure whether that is always assigned to the begin end block EXPR
            code_pos = get_file_loc(child_nodes[end])[2] + 1 + length("begin")

            code_range = code_pos:code_pos+child_nodes[end].span - 1 - length("begin") - length("end")

            push!(testitems, (name=CSTParser.valof(node.args[3]), range=range, code_range=code_range, option_default_imports=option_default_imports, option_tags=option_tags, option_setup=option_setup))
        end
    elseif node.head == :macrocall && length(node.args)>0 && CSTParser.valof(node.args[1]) == "@testsetup"
        pos = 1 + get_file_loc(node)[2]
        range = pos:pos+node.span-1

        # filter out line nodes
        child_nodes = filter(i->!(isa(i, EXPR) && i.head==:NOTHING && i.args===nothing), node.args)

        # Check for various syntax errors
        if length(child_nodes)==1
            push!(errors, (error="Your `@testsetup` is missing a `module ... end` block.", range=range))
            return
        elseif length(child_nodes)>2 || !(child_nodes[2] isa EXPR && child_nodes[2].head==:module)
            push!(errors, (error="Your `@testsetup` must have a single `module ... end` argument.", range=range))
            return
        else
            # TODO + 1 here is from the space before the module block. We might have to detect that,
            # not sure whether that is always assigned to the module end EXPR
            mod = child_nodes[2]
            mod_name = CSTParser.valof(mod[3])
            preamble = 1 + length("module") + 1 + length(mod_name)
            code_pos = get_file_loc(mod)[2] + preamble
            code_range = code_pos:(code_pos + mod.span - preamble - length("end"))
            push!(testsetups, (name=mod_name, range=range, code_range=code_range))
        end
    elseif node.head == :module && length(node.args)>=3 && node.args[3] isa EXPR && node.args[3].head==:block
        for i in node.args[3].args
            find_test_detail!(i, testitems, testsetups, errors)
        end
    end
end

function vec_startswith(a, b)
    if length(a) < length(b)
        return false
    end

    for (i,v) in enumerate(b)
        if a[i] != v
            return false
        end
    end
    return true
end

function find_package_for_file(jw::JuliaWorkspace, file::URI)
    file_path = uri2filepath(file)
    package = jw._packages |>
        keys |>
        collect |>
        x -> map(x) do i
            package_folder_path = uri2filepath(i)
            parts = splitpath(package_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return package
end

function find_project_for_file(jw::JuliaWorkspace, file::URI)
    file_path = uri2filepath(file)
    project = jw._projects |>
        keys |>
        collect |>
        x -> map(x) do i
            project_folder_path = uri2filepath(i)
            parts = splitpath(project_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return project
end

function find_tests_in_file!(jw, uri, cst, fallback_project_uri)
    # Find which workspace folder the doc is in.
    parent_workspaceFolders = sort(filter(f -> startswith(string(uri), string(f)), collect(jw._workspace_folders)), by=length, rev=true)

    # If the file is not in the workspace, we don't report nothing
    isempty(parent_workspaceFolders) && return

    project_uri = find_project_for_file(jw, uri)
    package_uri = find_package_for_file(jw, uri)

    if project_uri === nothing
        project_uri = fallback_project_uri
    end

    if package_uri === nothing
        package_name = ""
    else
        package_name = jw._packages[package_uri].name
    end

    if haskey(jw._projects, project_uri)
        relevant_project = jw._projects[project_uri]

        if !haskey(relevant_project.deved_packages, package_uri)
            project_uri = nothing
        end
    else
        project_uri = nothing
    end

    testitems = []
    testsetups = []
    testerrors = []

    for i in cst.args
        find_test_detail!(i, testitems, testsetups, testerrors)
    end

    return (
        project_uri=project_uri,
        package_uri=package_uri,
        package_name=package_name,
        testitems=testitems,
        testsetups=testsetups,
        testerrors=testerrors
    )
end
