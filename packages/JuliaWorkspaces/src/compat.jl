@static if VERSION < v"1.6"
    let
        @inline function __convert_digit(_c::UInt32, base)
            _0 = UInt32('0')
            _9 = UInt32('9')
            _A = UInt32('A')
            _a = UInt32('a')
            _Z = UInt32('Z')
            _z = UInt32('z')
            a::UInt32 = base <= 36 ? 10 : 36
            d = _0 <= _c <= _9 ? _c - _0 :
                _A <= _c <= _Z ? _c - _A + UInt32(10) :
                _a <= _c <= _z ? _c - _a + a : UInt32(base)
        end

        @inline function uuid_kernel(s, i, u)
            _c = UInt32(@inbounds codeunit(s, i))
            d = __convert_digit(_c, UInt32(16))
            d >= 16 && return nothing
            u <<= 4
            return u | d
        end

        function Base.tryparse(::Type{UUID}, s::AbstractString)
            u = UInt128(0)
            ncodeunits(s) != 36 && return nothing
            for i in 1:8
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 9) == UInt8('-') || return nothing
            for i in 10:13
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 14) == UInt8('-') || return nothing
            for i in 15:18
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 19) == UInt8('-') || return nothing
            for i in 20:23
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 24) == UInt8('-') || return nothing
            for i in 25:36
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            return Base.UUID(u)
        end
    end
end
