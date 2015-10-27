VERSION >= v"0.4.0-dev+6521" && __precompile__()
module Roots

import Base: *
import Base: factor

using Polynomials
import Polynomials: roots

using ForwardDiff
using Compat

if VERSION < v"0.4-" 
    eval(parse("using Docile"))
    eval(parse("Docile.@document"))
end

export roots

export fzero,
       fzeros,
       newton, halley,
       secant_method, steffensen,
       multroot, 
       D, D2


## load in files
include("fzero.jl")
include("adiff.jl")
include("derivative_free.jl")
include("newton.jl")
include("multroot.jl")
include("SOLVE.jl")
include("real_roots.jl")


## Main functions are
## * fzero(f, ...) to find _a_ zero of f
## * fzeros(f, ...) to attempt to find all zeros of f



"""

Find zero of a function using an iterative algorithm

* `f`: a scalar function or callable object
* `x0`: an initial guess, finite valued.

Keyword arguments:

* `ftol`: tolerance for a guess `abs(f(x)) < ftol`
* `xtol`: stop if `abs(xold - xnew) <= xtol + max(1, |xnew|)*xtolrel`
* `xtolrel`: see `xtol`
* `maxeval`: maximum number of steps
* `verbose`: Boolean. Set `true` to trace algorithm
* `order`: Can specify order of algorithm. 0 is most robust, also 1, 2, 5, 8, 16.
* `kwargs...` passed on to different algorithms. There are `maxfneval` when `order` is 1,2,5,8, or 16 and `beta` for orders 2,5,8,16,

This is a polyalgorithm redirecting different algorithms based on the value of `order`. 

"""
function fzero(f, x0::Real; kwargs...)
    x0 = float(x0)
    isinf(x0) && throw(ConvergenceFailed("An initial value must be finite"))
    derivative_free(f, float(x0); kwargs...)
end

"""
Find zero of a function within a bracket

Uses a modified bisection method for non `big` arguments

Arguments:

* `f` A scalar function or callable object
* `a` left endpont of interval
* `b` right endpont of interval
* `xtol` optional additional tolerance on sub-bracket size.

For a bracket to be valid, it must be that `f(a)*f(b) < 0`.

For `Float64` values, the answer is such that `f(prevfloat(x)) *
f(nextfloat(x)) < 0` unless a non-zero value of `xtol` is specified in
which case, it stops when the sub-bracketing produces an bracket with
length less than `max(xtol, abs(x1)*xtolrel)`. 

For `Big` values, which defaults to the algorithm of Alefeld, Potra, and Shi, a
default tolerance is used for the sub-bracket length that can be enlarged with `xtol`.

If `a==-Inf` it is replaced with `nextfloat(a)`; if `b==Inf` it is replaced with `prevfloat(b)`.

Example:

    `fzero(sin, 3, 4)` # find pi
    `fzero(sin, [big(3), 4]) find pi with more digits
"""
function fzero(f, a::Real, b::Real; kwargs...)
    a,b = sort([a,b])
    a,b = promote(float(a), b)
    (a == -Inf) && (a = nextfloat(a))
    (b == Inf) && (b = prevfloat(b))
    (isinf(a) | isinf(b)) && throw(ConvergenceFailed("A bracketing interval must be bounded"))
    find_zero(f,a,b; kwargs...)
end

"""
Find a zero with bracket specified via `[a,b]`, as `fzero(sin, [3,4])`.
"""
function fzero{T <: Real}(f, bracket::Vector{T}; kwargs...) 
    fzero(f, float(bracket[1]), float(bracket[2]); kwargs...)
end

"""
Find a zero within a bracket with an initial guess to *possibly* speed things along.
"""
function fzero{T <: Real}(f, x0::Real, bracket::Vector{T}; kwargs...) 
    a,b = sort(map(float,bracket))
    (a == -Inf) && (a = nextfloat(a))
    (b == Inf) && (b = prevfloat(b))
    (isinf(a) | isinf(b)) && throw(ConvergenceFailed("A bracketing interval must be bounded"))    
    try
        ex = a42a(f, a, b, float(x0); kwargs...)
    catch ex
        if isa(ex, StateConverged) 
            return(ex.x0)
        else
            rethrow(ex)
        end
    end
end


"""
Find zero using Newton's method.
"""
fzero(f::Function, fp::Function, x0::Real; kwargs...) = newton(f, fp, float(x0); kwargs...)



"""

Find zero of a polynomial with derivative free algorithm.

Arguments:

* `p` a `Poly` object
* `x0` an initial guess

Returns:

An approximate root or an error.

See `fzeros(p)` to return all real roots.

"""
function fzero(p::Poly, x0::Real, args...; kwargs...)
    fzero(convert(Function, p), float(x0), args...; kwargs...)
end

function fzero{T <: Real}(p::Poly, bracket::Vector{T}; kwargs...) 
    a, b = float(bracket[1]), float(bracket[2])
    fzero(convert(Function, p), a, b; kwargs...)
end
function fzero{T <: Real}(p::Poly, x0::Real, bracket::Vector{T}; kwargs...) 
    fzero(convert(Function,p), float(x0), map(float,bracket); kwargs...)
end


## fzeros

"""

Find real zeros of a polynomial

args:

`f`: a Polynomial function of R -> R. May also be of `Poly` type.

For polynomials in Z[x] or Q[x], the `real_roots` method will use
`Poly{Rational{BigInt}}` arithmetic, which allows it to handle much
larger degree polynomials accurately. This can be called directly
using `Polynomial` objects.

"""
fzeros(p::Poly) = real_roots(p)



function fzeros(f)
    p = poly([0.0])
    try
        p = convert(Poly, f)
    catch e
        error("If f(x) is not a polynomial in x, then an interval to search over is needed")
    end
    fzeros(p)
end

"""

Attempt to find all simple zeroes of `f` within an interval `[a,b]`.

Simple algorithm that splits `[a,b]` into `no_pts::Int=200` subintervals and checks each for a bracket or a quick zero.

"""        
function fzeros{T <: Real}(f, bracket::Vector{T}; kwargs...) 
    ## check if a poly
    try
        filter(x -> bracket[1] <= x <= bracket[2], real_roots(convert(Poly, f)))
    catch e
        find_zeros(f, float(bracket[1]), float(bracket[2]); kwargs...)
    end
end
fzeros(f::Function, a::Real, b::Real; kwargs...) = fzeros(f, [a,b]; kwargs...)


"""

Factor a polynomial function.

Finds factors numerically.

For polynomial functions with integer and rational tries to factor exactly over the rationals first.

Returns a dictionary with keys that are roots and values that are multiplicities

Example:
```
factor(x -> (x-1)^3*(x-2)) 
```

"""
function Base.factor(f::Function)
    p = poly([0.0])
    try
        p = convert(Poly, f)
    catch e
        throw(DomainError()) # `factor` only works with polynomial functions"
    end
    factor(p)
end


end

