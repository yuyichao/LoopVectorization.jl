
### This file contains convenience functions for constructing LoopSets.

# function strip_unneeded_const_deps!(ls::LoopSet)
#     for op ∈ operations(ls)
#         if isconstant(op) && iszero(length(reducedchildren(op)))
#             op.dependencies = NODEPENDENCY
#         end
#     end
#     ls
# end

function Base.copyto!(ls::LoopSet, q::Expr)
    q.head === :for || throw("Expression must be a for loop.")
    add_loop!(ls, q, 8)
    # strip_unneeded_const_deps!(ls)
end

function add_ci_call!(q::Expr, @nospecialize(f), args, syms, i, valarg = nothing, mod = nothing)
    call = if f isa Core.SSAValue
        Expr(:call, syms[f.id])
    else
        Expr(:call, f)
    end
    for arg ∈ @view(args[2:end])
        if arg isa Core.SSAValue
            push!(call.args, syms[arg.id])
        else
            push!(call.args, arg)
        end
    end
    if mod !== nothing # indicates it's `vmaterialize(!)`
        push!(call.args, Expr(:call, Expr(:curly, :Val, QuoteNode(mod))), valarg)
    end
    push!(q.args, Expr(:(=), syms[i], call))
end

function substitute_broadcast(q::Expr, mod::Symbol, inline, u₁, u₂, threads)
    ci = first(Meta.lower(LoopVectorization, q).args).code
    nargs = length(ci)-1
    ex = Expr(:block)
    syms = [gensym() for _ ∈ 1:nargs]
    configarg = (inline,u₁,u₂,true,threads)
    unroll_param_tup = Expr(:call, lv(:avx_config_val), :(Val{$configarg}()), staticexpr(0))
    for n ∈ 1:nargs
        ciₙ = ci[n]
        ciₙargs = ciₙ.args
        f = first(ciₙargs)
        if ciₙ.head === :(=)
            push!(ex.args, Expr(:(=), f, syms[((ciₙargs[2])::Core.SSAValue).id]))
        elseif isglobalref(f, Base, :materialize!)
            add_ci_call!(ex, lv(:vmaterialize!), ciₙargs, syms, n, unroll_param_tup, mod)
        elseif isglobalref(f, Base, :materialize)
            add_ci_call!(ex, lv(:vmaterialize), ciₙargs, syms, n, unroll_param_tup, mod)
        else
            add_ci_call!(ex, f, ciₙargs, syms, n)
        end
    end
    esc(ex)
end


function LoopSet(q::Expr, mod::Symbol = :Main)
    contract_pass!(q)
    ls = LoopSet(mod)
    copyto!(ls, q)
    resize!(ls.loop_order, num_loops(ls))
    ls
end
LoopSet(q::Expr, m::Module) = LoopSet(macroexpand(m, q)::Expr, Symbol(m))

function loopset(q::Expr) # for interactive use only
    ls = LoopSet(q)
    set_hw!(ls)
    ls
end

function check_macro_kwarg(arg, inline::Bool, check_empty::Bool, u₁::Int8, u₂::Int8, threads::Int)
    ((arg.head === :(=)) && (length(arg.args) == 2)) || throw(ArgumentError("macro kwarg should be of the form `argname = value`."))
    kw = (arg.args[1])::Symbol
    value = (arg.args[2])
    if kw === :inline
        inline = value::Bool
    elseif kw === :unroll
        if value isa Integer
            u₁ = convert(Int8, value)::Int8
        elseif Meta.isexpr(value,:tuple,2)
            u₁ = convert(Int8, value.args[1])::Int8
            u₂ = convert(Int8, value.args[2])::Int8
        else
            throw(ArgumentError("Don't know how to process argument in `unroll=$value`."))
        end
    elseif kw === :check_empty
        check_empty = value::Bool
    elseif kw === :thread
        if value isa Bool
            threads = Core.ifelse(value::Bool, -1, 1)
        elseif value isa Integer
            threads = max(1, convert(Int,value)::Int)
        else
            throw(ArgumentError("Don't know how to process argument in `thread=$value`."))
        end
    else
        throw(ArgumentError("Received unrecognized keyword argument $kw. Recognized arguments include:\n`inline`, `unroll`, `check_empty`, and `thread`."))
    end
    inline, check_empty, u₁, u₂, threads
end
function process_args(args; inline = false, check_empty = false, u₁ = zero(Int8), u₂ = zero(Int8), threads = 1)
    for arg ∈ args
        inline, check_empty, u₁, u₂, threads = check_macro_kwarg(arg, inline, check_empty, u₁, u₂, threads)
    end
    inline, check_empty, u₁, u₂, threads
end
function spmd_macro(mod, src, q, args...)
    q = macroexpand(mod, q)
    
    if q.head === :for
        ls = LoopSet(q, mod)
        inline, check_empty, u₁, u₂, threads = process_args(args)
        esc(setup_call(ls, q, src, inline, check_empty, u₁, u₂, threads))
    else
        inline, check_empty, u₁, u₂, threads = process_args(args, inline=true)
        substitute_broadcast(q, Symbol(mod), inline, u₁, u₂, threads)
    end
end
"""
    @spmd

Annotate a `for` loop, or a set of nested `for` loops whose bounds are constant across iterations, to optimize the computation. For example:

    function AmulB!(C, A, B)
        @spmd for m ∈ 1:size(A,1), n ∈ 1:size(B,2)
            Cₘₙ = zero(eltype(C))
            for k ∈ 1:size(A,2)
                Cₘₙ += A[m,k] * B[k,n]
            end
            C[m,n] = Cₘₙ
        end
    end

The macro models the set of nested loops, and chooses an ordering of the three loops to
minimize predicted computation time.

It may also apply to broadcasts:

```jldoctest
julia> using LoopVectorization

julia> a = rand(100);

julia> b = @spmd exp.(2 .* a);

julia> c = similar(b);

julia> @spmd @. c = exp(2a);

julia> b ≈ c
true
```

# Extended help

Advanced users can customize the implementation of the `@spmd`-annotated block
using keyword arguments:

```
@spmd inline=false unroll=2 body
```

where `body` is the code of the block (e.g., `for ... end`).

`thread` is either a Boolean, or an integer.
The integer's value indicates the number of threads to use.
It is clamped to be between `1` and `min(Threads.nthreads(),LoopVectorization.num_cores())`.
`false` is equivalent to `1`, and `true` is equivalent to `min(Threads.nthreads(),LoopVectorization.num_cores())`.

`inline` is a Boolean. When `true`, `body` will be directly inlined
into the function (via a forced-inlining call to `_avx_!`).
When `false`, it wont force inlining of the call to `_avx_!` instead, letting Julia's own inlining engine
determine whether the call to `_avx_!` should be inlined. (Typically, it won't.)
Sometimes not inlining can lead to substantially worse code generation, and >40% regressions, even in very
large problems (2-d convolutions are a case where this has been observed).
One can find some circumstances where `inline=true` is faster, and other circumstances
where `inline=false` is faster, so the best setting may require experimentation. By default, the macro
tries to guess. Currently the algorithm is simple: roughly, if there are more than two dynamically sized loops
or and no convolutions, it will probably not force inlining. Otherwise, it probably will.

`check_empty` (default is `false`) determines whether or not it will check if any of the iterators are empty.
If false, you must ensure yourself that they are not empty, else the behavior of the loop is undefined and
(like with `@inbounds`) segmentation faults are likely.

`unroll` is an integer that specifies the loop unrolling factor, or a
tuple `(u₁, u₂) = (4, 2)` signaling that the generated code should unroll more than
one loop. `u₁` is the unrolling factor for the first unrolled loop and `u₂` for the next (if present),
but it applies to the loop ordering and unrolling that will be chosen by LoopVectorization,
*not* the order in `body`.
`uᵢ=0` (the default) indicates that LoopVectorization should pick its own value,
and `uᵢ=-1` disables unrolling for the correspond loop.

The `@spmd` macro also checks the array arguments using `LoopVectorization.check_args` to try and determine
if they are compatible with the macro. If `check_args` returns false, a fall back loop annotated with `@inbounds`
and `@fastmath` is generated. Note that `VectorizationBase` provides functions such as `vadd` and `vmul` that will
ignore `@fastmath`, preserving IEEE semantics both within `@spmd` and `@fastmath`.
`check_args` currently returns false for some wrapper types like `LinearAlgebra.UpperTriangular`, requiring you to
use their `parent`. Triangular loops aren't yet supported.
"""
macro spmd(args...)
    spmd_macro(__module__, __source__, last(args), Base.front(args)...)
end
"""
Equivalent to `@spmd`, except it adds `thread=true` as the first keyword argument.
Note that later arguments take precendence.

Meant for convenience, as `@spmdt` is shorter than `@spmd thread=true`.
"""
macro spmdt(args...)
    spmd_macro(__module__, __source__, last(args), :(thread=true), Base.front(args)...)
end

"""
    @_spmd

This macro mostly exists for debugging/testing purposes. It does not support many of the use cases of [`@spmd`](@ref).
It emits loops directly, rather than punting to an `@generated` function, meaning it doesn't have access to type
information when generating code or analyzing the loops, often leading to bad performance.

This macro accepts the `inline` and `unroll` keyword arguments like `@spmd`, but ignores the `check_empty` argument.
"""
macro _spmd(q)
    q = macroexpand(__module__, q)
    ls = LoopSet(q, __module__)
    set_hw!(ls)
    esc(Expr(:block, ls.prepreamble, lower_and_split_loops(ls, -1)))
end
macro _spmd(arg, q)
    @assert q.head === :for
    q = macroexpand(__module__, q)
    inline, check_empty, u₁, u₂ = check_macro_kwarg(arg, false, false, zero(Int8), zero(Int8), 1)
    ls = LoopSet(q, __module__)
    set_hw!(ls)
    esc(Expr(:block, ls.prepreamble, lower(ls, u₁ % Int, u₂ % Int, -1)))
end

macro spmd_debug(q)
    q = macroexpand(__module__, q)
    ls = LoopSet(q, __module__)
    esc(LoopVectorization.setup_call_debug(ls))
end

# define aliases
const var"@avx" = var"@spmd"
const var"@avxt" = var"@spmdt"
const var"@avx_debug" = var"@spmd_debug"

