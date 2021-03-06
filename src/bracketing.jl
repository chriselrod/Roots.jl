###

# type to throw on succesful convergence
mutable struct StateConverged
    x0::Real
end

# type to throw on failure
mutable struct ConvergenceFailed
    reason::AbstractString
end

bracketing_error = """The interval [a,b] is not a bracketing interval.
You need f(a) and f(b) to have different signs (f(a) * f(b) < 0).
Consider a different bracket or try fzero(f, c) with an initial guess c.

"""

## Methods for root finding which use a bracket

## Bisection for FLoat64 values.
##
## From Jason Merrill https://gist.github.com/jwmerrill/9012954
## cf. http://squishythinking.com/2014/02/22/bisecting-floats/
# Alternative "mean" definition that operates on the binary representation
# of a float. Using this definition, bisection will never take more than
# 64 steps.
const FloatNN = Union{Float64, Float32, Float16}
_float_int_pairs = Dict(Float64 => UInt64, Float32 => UInt32, Float16 => UInt16)

function _middle(x::T, y::T) where {T <: FloatNN}
    # Use the usual float rules for combining non-finite numbers
    if !isfinite(x) || !isfinite(y)
        return x + y
    end
    # Always return 0.0 when inputs have opposite sign
    if sign(x) != sign(y) && !iszero(x) && ! iszero(y)
        return zero(T)
    end
    
    negate = sign(x) < 0 || sign(y) < 0 

    # do division over unsigned integers with bit shift
    xint = reinterpret(_float_int_pairs[T], abs(x))
    yint = reinterpret(_float_int_pairs[T], abs(y))
    mid = (xint + yint) >> 1

    # reinterpret in original floating point
    unsigned = reinterpret(T, mid)

    negate ? -unsigned : unsigned
end

## fall back or non Floats
function _middle(x::Real, y::Real)
    x + (y-x)/2
end


"""

    Roots.bisection64(f, a, b)

(unexported)

* `f`: a callable object, like a function

* `a`, `b`: Real values specifying a *bracketing* interval (one with
`f(a) * f(b) < 0`). These will be converted to `Float64` values.

Runs the bisection method using midpoints determined by a trick
leveraging 64-bit floating point numbers. After ensuring the
intermediate bracketing interval does not straddle 0, the "midpoint"
is half way between the two values onces converted to unsigned 64-bit
integers. This means no more than 64 steps will be taken, fewer if `a`
and `b` already share some bits.

The process is guaranteed to return a value `c` with `f(c)` one of
`0`, `Inf`, or `NaN`; *or* one of `f(prevfloat(c))*f(c) < 0` or
`f(c)*f(nextfloat(c)) > 0` holding. 

This function is a bit faster than the slightly more general 
`find_zero(f, [a,b], Bisection())` call.

Due to Jason Merrill.

"""
function bisection64(@nospecialize(f), a0::FloatNN, b0::FloatNN)

    a,b = promote(a0, b0)


    if a > b
        b,a = a, b
    end
    
    
    m = _middle(a,b)

    fa, fb = sign(f(a)), sign(f(b))

    
    fa * fb > 0 && throw(ArgumentError(bracketing_error)) 
    (iszero(fa) || isnan(fa) || isinf(fa)) && return a
    (iszero(fb) || isnan(fb) || isinf(fb)) && return b
    
    while a < m < b

        fm = sign(f(m))

        if iszero(fm) || isnan(fm) || isinf(fm)
            return m
        elseif fa * fm < 0
            b,fb=m,fm
        else
            a,fa=m,fm
        end
        m = _middle(a,b)
    end
    return m
end


####
## find_zero interface.
"""

    Bisection()

Use the bisection method over `Float64` values. The bisection method
starts with a bracketing interval `[a,b]` and splits it into two
intervals `[a,c]` and `[c,b]`, If `c` is not a zero, then one of these
two will be a bracketing interval and the process continues. The
computation of `c` is done by `_middle`, which reinterprets floating
point values as unsigned 64-bit integers and splits there. This method
avoids floating point issues and guarantees a "best" solution (one
where a zero is found or the bracketing interval is of the type `[a,
nextfloat(a)]`).
    
"""    
mutable struct Bisection <: AbstractBisection end

"""
    Roots.A42()

Bracketing method which finds the root of a continuous function within
a provided interval [a, b], without requiring derivatives. It is based
on algorithm 4.2 described in: 1. G. E. Alefeld, F. A. Potra, and
Y. Shi, "Algorithm 748: enclosing zeros of continuous functions," ACM
Trans. Math. Softw. 21, 327–344 (1995).
"""
mutable struct A42 <: AbstractBisection end


function find_zero(f, x0::Vector{T}, method::AbstractBisection; kwargs...) where {T <: Real}
    
    find_zero(f, (x0[1], x0[2]), method; kwargs...)
end

## For speed, bypass find_zero setup for bisection+Float64
function find_zero(f, x0::Tuple{T,S}, method::Bisection; verbose=false, kwargs...) where {T <: FloatNN, S <: FloatNN}
    x = adjust_bracket(x0)
    if verbose
        prob, options = derivative_free_setup(method, DerivativeFree(f), x; verbose=verbose, kwargs...)
        find_zero(prob, method, options)
    else
        bisection64(f, x[1], x[2])::eltype(x)
    end
end



## This is a bit clunky, as we use `a42` for bisection when we don't have `Float64` values.
## As we don't have the `A42` algorithm implemented through `find_zero`, we adjust here.
function find_zero(f, x0::Tuple{T,S}, method::M;  kwargs...) where {M <: Union{Bisection, A42}, T <: Real, S <: Real}

    x = adjust_bracket(x0)
    ## round about way to get options and state
    prob, options = derivative_free_setup(method, DerivativeFree(f), x[1];  kwargs...)
    o = init_state(method, prob.fs, prob.x0, prob.bracket)

    o.xn1 = a42(f, x[1], x[2]; xtol=options.xreltol, maxeval=options.maxevals, verbose=options.verbose)
    o.message = "Used Alefeld-Potra-Shi method, `Roots.a42`, to find the zero. Iterations and function evaluations are not counted properly."
    o.stopped = o.x_converged = true

    options.verbose && show_trace(prob.fs, o, [o.xn1], [o.fxn1], method)
    o.xn1
end


# this is hacky.
# we reach here from calling Bisection midway through the Order0() routine with "big" values.
# call a42 in this case
const BigSomething = Union{BigFloat, BigInt}
function find_zero(method::Bisection, fs, o::UnivariateZeroState{T, S}, options::UnivariateZeroOptions) where {T<:BigSomething, S}
    xn0, xn1 = o.xn0 < o.xn1 ? (o.xn0, o.xn1) : (o.xn1, o.xn0)
    o.xn1 = a42(fs, o.xn0, o.xn1; xtol=options.xreltol, maxeval=options.maxevals, verbose=options.verbose)
    o.message = "Used Alefeld-Potra-Shi method, `Roots.a42`, to find the zero. Iterations and function evaluations are not counted properly."
    o.stopped = o.x_converged = true

    nothing
end


function init_state(method::AbstractBisection, fs, x::Union{Tuple{T,T}, Vector{T}}, bracket) where {T <: Real}
    x0, x2 = adjust_bracket(x)
    y0 = fs(x0)
    y2 = fs(x2)

    sign(y0) * sign(y2) > 0 && throw(ArgumentError(bracketing_error))

    state = UnivariateZeroStateBase(x0, x2,
                                    y0, y2,
                                    ismissing(bracket) ? bracket : float.(bracket),
                                    0, 2,
                                    false, false, false, false,
                                    "")
    state
end


## This uses _middle bisection
## Find zero using modified bisection method for Float64 arguments.
## This is guaranteed to take no more than 64 steps. The `a42` alternative usually has
## fewer iterations, but this seems to find the value with fewer function evaluations.
##
## Terminates with `x1` when the bracket length of `[x0,x2]` is `<= max(xtol, xtolrel*abs(x1))` where `x1` is the midpoint .
## The tolerances can be set to 0, in which case, the termination occurs when `nextfloat(x0) = x2`.
## The bracket `[a,b]` must be bounded.

function update_state(method::Bisection, fs, o::Roots.UnivariateZeroState{T,S}, options::UnivariateZeroOptions) where {T<:FloatNN,S}
    x0, x2 = o.xn0, o.xn1
    y0, y2 = o.fxn0, o.fxn1

    x1 = _middle(x0, x2)

    y1 = fs(x1)
    incfn(o)

    if sign(y0) * sign(y1) > 0
        x0, x2 = x1, x2
        y0, y2 = y1, y2
    else
        x0, x2 = x0, x1
        y0, y2 = y0, y1
    end

    o.xn0, o.xn1 = x0, x2
    o.fxn0, o.fxn1 = y0, y2
    incsteps(o)
    nothing
end

## convergence is much differen there, as we bound between x0, nextfloat(x0) is not measured by eps(), but eps(x0)
function assess_convergence(method::Bisection, fs, state, options)
    x0, x2 = state.xn0, state.xn1
    if x0 > x2
        x0, x2 = x2, x0
    end

    x1 = _middle(x0, x2)
    if iszero(state.fxn1)
        state.message = ""
        state.stopped = state.x_converged = true
        return true
    end
    x0 < x1 && x1 < x2 && return false

    state.message = ""
    state.stopped = state.x_converged = true
    true
end


##################################################

"""

    Roots.a42(f, a, b; kwargs...)

(not exported)

Finds the root of a continuous function within a provided
interval [a, b], without requiring derivatives. It is based on algorithm 4.2
described in: 1. G. E. Alefeld, F. A. Potra, and Y. Shi, "Algorithm 748:
enclosing zeros of continuous functions," ACM Trans. Math. Softw. 21,
327–344 (1995).


input:
    `f`: function to find the root of
    `a`, `b`: the initial bracket, with: a < b, f(a)*f(b) < 0
    `xtol`: acceptable error (it's safe to set zero for machine precision)
    `maxeval`:  maximum number of iterations

output:
    an estimate of the zero of f

By John Travers

"""
function a42(f, a, b;
      xtol=zero(float(a)),
      maxeval::Int=15,
      verbose::Bool=false)

    if a > b
        a,b = b,a
    end
    fa, fb = f(a), f(b)

    if a >= b || sign(fa)*sign(fb) >= 0
        error("on input a < b and f(a)f(b) < 0 must both hold")
    end
    if xtol < 0.0
        error("tolerance must be >= 0.0")
    end

    c, fc = secant(f, a, fa, b, fb)
    a42a(f, a, fa, b, fb, c, fc,
         xtol=xtol, maxeval=maxeval, verbose=verbose)
end

"""

Split Alefeld, F. A. Potra, and Y. Shi algorithm 4.2 into a function
where `c` is passed in.

Solve f(x) = 0 over bracketing interval [a,b] starting at c, with a < c < b

"""
a42a(f, a, b, c=(a+b)/2; args...) = a42a(f, a, f(a), b, f(b), c, f(c); args...)

function a42a(f, a, fa, b, fb, c, fc;
       xtol=zero(float(a)),
       maxeval::Int=15,
       verbose::Bool=false)

    try
        # re-bracket and check termination
        a, fa, b, fb, d, fd = bracket(f, a, fa, b, fb, c, fc, xtol)
        ee, fee = d, fd
        for n = 2:maxeval
            # use either a cubic (if possible) or quadratic interpolation
            if n > 2 && distinct(a, fa, b, fb, d, fd, ee, fee)
                c, fc = ipzero(f, a, fa, b, fb, d, fd, ee, fee)
            else
                c, fc = newton_quadratic(f, a, fa, b, fb, d, fd, 2)
            end
            # re-bracket and check termination
            ab, fab, bb, fbb, db, fdb = bracket(f, a, fa, b, fb, c, fc, xtol)
            eb, feb = d, fd
            # use another cubic (if possible) or quadratic interpolation
            if distinct(ab, fab, bb, fbb, db, fdb, eb, feb)
                cb, fcb = ipzero(f, ab, fab, bb, fbb, db, fdb, eb, feb)
            else
                cb, fcb = newton_quadratic(f, ab, fab, bb, fbb, db, fdb, 3)
            end
            # re-bracket and check termination
            ab, fab, bb, fbb, db, fdb = bracket(f, ab, fab, bb, fbb, cb, fcb, xtol)
            # double length secant step; if we fail, use bisection
            if abs(fab) < abs(fbb)
                u, fu = ab, fab
            else
                u, fu = bb, fbb
            end
            # u = abs(fab) < abs(fbb) ? ab : bb
            cb = u - 2*fu/(fbb - fab)*(bb - ab)
            fcb = f(cb)
            if abs(cb - u) > (bb - ab)/2
                ch, fch = ab+(bb-ab)/2, f(ab+(bb-ab)/2)
            else
                ch, fch = cb, fcb
            end
            # ch = abs(cb - u) > (bb - ab)/2 ? ab + (bb - ab)/2 : cb
            # re-bracket and check termination
            ah, fah, bh, fbh, dh, fdh = bracket(f, ab, fab, bb, fbb, ch, fch, xtol)
            # if not converging fast enough bracket again on a bisection
            if bh - ah < 0.5*(b - a)
                a, fa = ah, fah
                b, fb = bh, fbh
                d, fd = dh, fdh
                ee, fee = db, fdb
            else
                ee, fee = dh, fdh
                a, fa, b, fb, d, fd = bracket(f, ah, fah, bh, fbh, ah + (bh - ah)/2, f(ah+(bh-ah)/2), xtol)
            end

            verbose && println(@sprintf("a=%18.15f, n=%s", float(a), n))

            if nextfloat(ch) * prevfloat(ch) <= 0
                throw(StateConverged(ch))
            end
            if nextfloat(a) >= b
                throw(StateConverged(a))
            end
        end
        throw(ConvergenceFailed("More than $maxeval iterations before convergence"))
    catch ex
        if isa(ex, StateConverged)
            return ex.x0
        else
            rethrow(ex)
        end
    end
    throw(ConvergenceFailed("More than $maxeval iterations before convergence"))
end



# calculate a scaled tolerance
# based on algorithm on page 340 of [1]
function tole(a::S, b::R, fa, fb, tol) where {S,R}
    T = promote_type(S,R)
    u = abs(fa) < abs(fb) ? abs(a) : abs(b)
    2u*eps(T) + tol
end


# bracket the root
# inputs:
#     - f: the function
#     - a, b: the current bracket with a < b, f(a)f(b) < 0
#     - c within (a,b): current best guess of the root
#     - tol: desired accuracy
#
# if root is not yet found, return
#     ab, bb, d
# with:
#     - [ab, bb] a new interval within [a, b] with f(ab)f(bb) < 0
#     - d a point not inside [ab, bb]; if d < ab, then f(ab)f(d) > 0,
#       and f(d)f(bb) > 0 otherwise
#
# if the root is found, throws a StateConverged instance with x0 set to the
# root.
#
# based on algorithm on page 341 of [1]
function bracket(f, a, fa, b, fb, c, fc, tol)

    if !(a <= c <= b)
        error("c must be in (a,b)")
    end
    delta = 0.7*tole(a, b, fa, fb, tol)
    if b - a <= 4delta
        c = (a + b)/2
        fc = f(c)
    elseif c <= a + 2delta
        c = a + 2delta
        fc = f(c)
    elseif c >= b - 2delta
        c = b - 2delta
        fc = f(c)
    end
    if fc == 0
        throw(Roots.StateConverged(c))
    elseif sign(fa)*sign(fc) < 0
        aa, faa = a, fa
        bb, fbb = c, fc
        db, fdb = b, fb
    else
        aa, faa = c, fc
        bb, fbb = b, fb
        db, fdb = a, fa
    end
    if bb - aa < 2*tole(aa, bb, faa, fbb, tol)
        x0 = abs(faa) < abs(fbb) ? aa : bb
        throw(Roots.StateConverged(x0))
    end
    aa, faa, bb, fbb, db, fdb
end


# take a secant step, if the resulting guess is very close to a or b, then
# use bisection instead
function secant(f, a::T, fa, b, fb) where {T}

    c = a - fa/(fb - fa)*(b - a)
    tol = eps(T)*5
    if isnan(c) || c <= a + abs(a)*tol || c >= b - abs(b)*tol
        return a + (b - a)/2, f(a+(b-a)/2)
    end
    return c, f(c)
end


# approximate zero of f using quadratic interpolation
# if the new guess is outside [a, b] we use a secant step instead
# based on algorithm on page 330 of [1]
function newton_quadratic(f, a, fa, b, fb, d, fd, k::Int)
    B = (fb - fa)/(b - a)
    A = ((fd - fb)/(d - b) - B)/(d - a)
    if A == 0
        return secant(f, a, fa, b, fb)
    end
    r = A*fa > 0 ? a : b
    for i = 1:k
        r -= (fa + (B + A*(r - b))*(r - a))/(B + A*(2*r - a - b))
    end
    if isnan(r) || (r <= a || r >= b)
        r, fr = secant(f, a, fa, b, fb)
    else
        fr = f(r)
    end
    return r, fr
end


# approximate zero of f using inverse cubic interpolation
# if the new guess is outside [a, b] we use a quadratic step instead
# based on algorithm on page 333 of [1]
function ipzero(f, a, fa, b, fb, c, fc, d, fd)

    Q11 = (c - d)*fc/(fd - fc)
    Q21 = (b - c)*fb/(fc - fb)
    Q31 = (a - b)*fa/(fb - fa)
    D21 = (b - c)*fc/(fc - fb)
    D31 = (a - b)*fb/(fb - fa)
    Q22 = (D21 - Q11)*fb/(fd - fb)
    Q32 = (D31 - Q21)*fa/(fc - fa)
    D32 = (D31 - Q21)*fc/(fc - fa)
    Q33 = (D32 - Q22)*fa/(fd - fa)
    c = a + (Q31 + Q32 + Q33)
    if (c <= a) || (c >= b)
        return newton_quadratic(f, a, fa, b, fb, d, fd, 3)
    end
    return c, f(c)
end


# floating point comparison function
function almost_equal(x::T, y::T) where {T}
    min_diff = realmin(T)*32
    abs(x - y) < min_diff
end


# check that all interpolation values are distinct
function distinct(a, f1, b, f2, d, f3, e, f4)
    !(almost_equal(f1, f2) || almost_equal(f1, f3) || almost_equal(f1, f4) ||
      almost_equal(f2, f3) || almost_equal(f2, f4) || almost_equal(f3, f4))
end

## ----------------------------

"""

    FalsePosition()

Use the [false
position](https://en.wikipedia.org/wiki/False_position_method) method
to find a zero for the function `f` within the bracketing interval
`[a,b]`.

The false position method is a modified bisection method, where the
midpoint between `[a_k, b_k]` is chosen to be the intersection point
of the secant line with the x axis, and not the average between the
two values.

To speed up convergence for concave functions, this algorithm
implements the 12 reduction factors of Galdino (*A family of regula
falsi root-finding methods*). These are specified by number, as in
`FalsePosition(2)` or by one of three names `FalsePosition(:pegasus)`,
`FalsePosition(:illinois)`, or `FalsePosition(:anderson_bjork)` (the
default). The default choice has generally better performance than the
others, though there are exceptions.

For some problems, the number of function calls can be greater than
for the `bisection64` method, but generally this algorithm will make
fewer function calls.

Examples
```
find_zero(x -> x^5 - x - 1, [-2, 2], FalsePosition())
```
"""    
# mutable struct FalsePosition <: AbstractBisection
#     reduction_factor::Union{Int, Symbol}
#     FalsePosition(x=:anderson_bjork) = new(x)
# end
struct FalsePosition{R} <: AbstractBisection
    FalsePosition(x=:anderson_bjork) = new{:anderson_bjork}()
end

function update_state(method::FalsePosition, fs, o, options)

    fs
    a, b =  o.xn0, o.xn1

    fa, fb = o.fxn0, o.fxn1

    lambda = fb / (fb - fa)
    tau = 1e-10                   # some engineering to avoid short moves
    if !(tau < norm(lambda) < 1-tau)
        lambda = 1/2
    end
    x = b - lambda * (b-a)        
    fx = fs(x)
    incfn(o)
    incsteps(o)

    if iszero(fx)
        o.xn1 = x
        o.fxn1 = fx
        return
    end

    if sign(fx)*sign(fb) < 0
        a, fa = b, fb
    else
        fa = reduction(method, fa, fb, fx)
    end
    b, fb = x, fx

    
    o.xn0, o.xn1 = a, b 
    o.fxn0, o.fxn1 = fa, fb
    
    nothing
end

# the 12 reduction factors offered by Galadino
const galdino = Dict{Union{Int,Symbol},Function}(:1 => (fa, fb, fx) -> fa*fb/(fb+fx),
                                           :2 => (fa, fb, fx) -> (fa - fb)/2,
                                           :3 => (fa, fb, fx) -> (fa - fx)/(2 + fx/fb),
                                           :4 => (fa, fb, fx) -> (fa - fx)/(1 + fx/fb)^2,
                                           :5 => (fa, fb, fx) -> (fa -fx)/(1.5 + fx/fb)^2,
                                           :6 => (fa, fb, fx) -> (fa - fx)/(2 + fx/fb)^2,
                                           :7 => (fa, fb, fx) -> (fa + fx)/(2 + fx/fb)^2,
                                           :8 => (fa, fb, fx) -> fa/2,
                                           :9 => (fa, fb, fx) -> fa/(1 + fx/fb)^2,
                                           :10 => (fa, fb, fx) -> (fa-fx)/4,
                                           :11 => (fa, fb, fx) -> fx*fa/(fb+fx),
                                           :12 => (fa, fb, fx) -> (fa * (1-fx/fb > 0 ? 1-fx/fb : 1/2))
)
# give common names
for (nm, i) in [(:pegasus, 1), (:illinois, 8), (:anderson_bjork, 12)]
    galdino[nm] = galdino[i]
end
@generated function reduction(method::FalsePosition{R}, fa, fb, fx) where R
    f = galdino[R]
    :( $f(fa, fb, fx) )
end

function find_zero(f, x0::Tuple{T,S}, method::FalsePosition; kwargs...) where {T<:Real,S<:Real}
    x = adjust_bracket(x0)
    prob, options = derivative_free_setup(method, DerivativeFree(f), x; kwargs...)
    find_zero(prob, method, options)
end
## helper function
function adjust_bracket(x0)
    u, v = float.(x0)
    if u > v
        u, v = v, u
    end


    if isinf(u)
        u = nextfloat(u)
    end
    if isinf(v)
        v = prevfloat(v)
    end
    u, v
end

## --------------------------------------

"""

Searches for zeros  of `f` in an interval [a, b].

Basic algorithm used:

* split interval [a,b] into `no_pts` subintervals.
* For each bracketing interval finds a bracketed zero.
* For other subintervals does a quick search with a derivative-free method.

If there are many zeros relative to the number of points, the process
is repeated with more points, in hopes of finding more zeros for
oscillating functions.

Called by `fzeros` or `Roots.find_zeros`.

"""
function find_zeros(f, a::Real, b::Real, args...;
                    no_pts::Int=100,
                    abstol::Real=10*eps(), reltol::Real=10*eps(), ## should be abstol, reltol as used. 
                    kwargs...)

    a, b = a < b ? (a,b) : (b,a)
    rts = eltype(promote(float(a),b))[]
    xs = vcat(a, a .+ (b-a) .* sort(rand(no_pts)), b)


    ## Look in [ai, bi)
    for i in 1:(no_pts+1)
        ai,bi=xs[i:i+1]
        if isapprox(f(ai), 0.0, rtol=reltol, atol=abstol)
            push!(rts, ai)
        elseif sign(f(ai)) * sign(f(bi)) < 0
            push!(rts, find_zero(f, [ai, bi], Bisection()))
        else
            try
                x = find_zero(f, ai + (0.5)* (bi-ai), Order8(); maxevals=10, abstol=abstol, reltol=reltol)
                if ai < x < bi
                    push!(rts, x)
                end
            catch e
            end
        end
    end
    ## finally, b?
    isapprox(f(b), 0.0, rtol=reltol, atol=abstol) && push!(rts, b)

    ## redo if it appears function oscillates alot in this interval...
    if length(rts) > (1/4) * no_pts
        return(find_zeros(f, a, b, args...; no_pts = 10*no_pts, abstol=abstol, reltol=reltol, kwargs...))
    else
        return(sort(rts))
    end
end
