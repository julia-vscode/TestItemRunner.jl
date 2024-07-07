function find_test_detail!(node, testitems, testsetups, testerrors)
    if kind(node) == K"macrocall" && haschildren(node) && node[1].val == Symbol("@testitem")
        range = first_byte(node):last_byte(node)

        child_nodes = children(node)

        # Check for various syntax errors
        if length(child_nodes)==1
            push!(testerrors, (message="Your @testitem is missing a name and code block.", range=range))
            return
        elseif length(child_nodes)>1 && !(kind(child_nodes[2]) == K"string")
            push!(testerrors, (message="Your @testitem must have a first argument that is of type String for the name.", range=range))
            return
        elseif length(child_nodes)==2
            push!(testerrors, (message="Your @testitem is missing a code block argument.", range=range))
            return
        elseif !(kind(child_nodes[end]) == K"block")
            push!(testerrors, (message="The final argument of a @testitem must be a begin end block.", range=range))
            return
        else
            option_tags = nothing
            option_default_imports = nothing
            option_setup = nothing

            # Now check our keyword args
            for i in child_nodes[3:end-1]
                if kind(i) != K"="
                    push!(testerrors, (message="The arguments to a @testitem must be in keyword format.", range=range))
                    return
                elseif !(length(children(i))==2)
                    error("This code path should not be possible.")
                elseif kind(i[1]) == K"Identifier" && i[1].val == :tags
                    if option_tags!==nothing
                        push!(testerrors, (message="The keyword argument tags cannot be specified more than once.", range=range))
                        return
                    end

                    if kind(i[2]) != K"vect"
                        push!(testerrors, (message="The keyword argument tags only accepts a vector of symbols.", range=range))
                        return
                    end

                    option_tags = Symbol[]

                    for j in children(i[2])
                        if kind(j) != K"quote" || length(children(j)) != 1 || kind(j[1]) != K"Identifier"
                            push!(testerrors, (message="The keyword argument tags only accepts a vector of symbols.", range=range))
                            return
                        end

                        push!(option_tags, j[1].val)
                    end
                elseif kind(i[1]) == K"Identifier" && i[1].val == :default_imports
                    if option_default_imports !== nothing
                        push!(testerrors, (message="The keyword argument default_imports cannot be specified more than once.", range=range))
                        return
                    end

                    if !(i[2].val in (true, false))
                        push!(testerrors, (message="The keyword argument default_imports only accepts bool values.", range=range))
                        return
                    end

                    option_default_imports = i[2].val
                elseif kind(i[1]) == K"Identifier" && i[1].val == :setup
                    if option_setup!==nothing
                        push!(testerrors, (message="The keyword argument setup cannot be specified more than once.", range=range))
                        return
                    end

                    if kind(i[2]) != K"vect"
                        push!(testerrors, (message="The keyword argument `setup` only accepts a vector of `@testsetup module` names.", range=range))
                        return
                    end

                    option_setup = Symbol[]

                    for j in children(i[2])
                        if kind(j) != K"Identifier"
                            push!(testerrors, (message="The keyword argument `setup` only accepts a vector of `@testsetup module` names.", range=range))
                            return
                        end

                        push!(option_setup, j.val)
                    end
                else
                    push!(testerrors, (message="Unknown keyword argument.", range=range))
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

            code_block = child_nodes[end]
            code_range = if haschildren(code_block) && length(children(code_block)) > 0
                first_byte(code_block[1]):last_byte(code_block[end])
            else
                (first_byte(code_block)+5):(last_byte(code_block)-3)
            end

            push!(testitems,
                    (
                    name=node[2,1].val,
                    range=range,
                    code_range=code_range,
                    option_default_imports=option_default_imports,
                    option_tags=option_tags,
                    option_setup=option_setup
                )
            )
        end
    elseif kind(node) == K"macrocall" && haschildren(node) && (node[1].val == Symbol("@testmodule") || node[1].val == Symbol("@testsnippet"))
        range = first_byte(node):last_byte(node)

        testkind = node[1].val

        child_nodes = children(node)

        # Check for various syntax errors
        if length(child_nodes)==1
            push!(testerrors, (message="Your $testkind is missing a name and code block.", range=range))
            return
        elseif length(child_nodes)>1 && !(kind(child_nodes[2]) == K"Identifier")
            push!(testerrors, (message="Your $testkind must have a first argument that is an identifier for the name.", range=range))
            return
        elseif length(child_nodes)==2
            push!(testerrors, (message="Your $testkind is missing a code block argument.", range=range))
            return
        elseif !(kind(child_nodes[end]) == K"block")
            push!(testerrors, (message="The final argument of a $testkind must be a begin end block.", range=range))
            return
        else
            # Now check our keyword args
            for i in child_nodes[3:end-1]
                if kind(i) != K"="
                    push!(testerrors, (message="The arguments to a $testkind must be in keyword format.", range=range))
                    return
                elseif !(length(children(i))==2)
                    error("This code path should not be possible.")
                else
                    push!(testerrors, (message="Unknown keyword argument.", range=range))
                    return
                end
            end

            mod_name = child_nodes[2].val
            code_block = child_nodes[end]
            code_range = if haschildren(code_block) && length(children(code_block)) > 0
                first_byte(code_block[1]):last_byte(code_block[end])
            else
                (first_byte(code_block)+5):(last_byte(code_block)-3)
            end

            testkind2 = if testkind==Symbol("@testmodule")
                :module
            elseif testkind==Symbol("@testsnippet")
                :snippet
            else
                error("Unknown testkind")
            end

            push!(
                testsetups,
                (
                    name=mod_name,
                    kind=testkind2,
                    range=range,
                    code_range=code_range
                )
            )
        end
    elseif kind(node) == K"toplevel"
        for i in children(node)
            find_test_detail!(i, testitems, testsetups, testerrors)
        end
    elseif kind(node) == K"module"
        find_test_detail!(node[2], testitems, testsetups, testerrors)
    elseif kind(node) == K"block"
        for i in children(node)
            find_test_detail!(i, testitems, testsetups, testerrors)
        end
    elseif kind(node) == K"doc"
        for i in children(node)
            find_test_detail!(i, testitems, testsetups, testerrors)
        end
    end
end
