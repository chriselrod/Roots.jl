using Roots
using Compat.Test
import SpecialFunctions.erf

include("./test_find_zero.jl")
#include("./RootTesting.jl")
#run_benchmark_tests()

include("./test_fzero.jl")

#include("./test_fzero3.jl")
#run_robustness_test()

include("./test_newton.jl")

#include("./test_derivative_free.jl")
