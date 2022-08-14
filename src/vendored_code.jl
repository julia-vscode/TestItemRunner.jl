function withpath(f, path)
    tls = task_local_storage()
    hassource = haskey(tls, :SOURCE_PATH)
    hassource && (path′ = tls[:SOURCE_PATH])
    tls[:SOURCE_PATH] = path
    try
        return f()
    finally
        hassource ? (tls[:SOURCE_PATH] = path′) : delete!(tls, :SOURCE_PATH)
    end
end

function descend(x::EXPR, target::EXPR, offset=0)
    x == target && return (true, offset)
    for c in x
        if c == target
            return true, offset
        end

        found, o = descend(c, target, offset)
        if found
            return true, o
        end
        offset += c.fullspan
    end
    return false, offset
end

function get_file_loc(x::EXPR, offset=0, c=nothing)
    parent = x
    while parentof(parent) !== nothing
        parent = parentof(parent)
    end

    if parent === nothing
        return nothing, offset
    end

    _, offset = descend(parent, x)

    # TODO Unclear what this was for but don't want to take dep on StaticLint
    # if headof(parent) === :file && StaticLint.hasmeta(parent)
    #     return parent.meta.error, offset
    # end
    return nothing, offset
end
