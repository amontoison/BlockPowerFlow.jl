# An implementation of block-GMRES for the solution of the square linear system AX = B.
#
# Alexis Montoison, <alexis.montoison@polymtl.ca>
# Chicago, October 2023.

export BlockGMRESSolver, block_gmres, block_gmres!

abstract type BlockKrylovSolver{T,FC,SV,SM} end

"""
Type for storing the vectors required by the in-place version of BLOCK-GMRES.

The outer constructors

    solver = BlockGMRESSolver(m, n, p, memory, SV, SM)
    solver = BlockGMRESSolver(A, B; memory=5)

may be used in order to create these vectors.
`memory` is set to `div(n,p)` if the value given is larger than `div(n,p)`.
"""
mutable struct BlockGMRESSolver{T,FC,SV,SM} <: BlockKrylovSolver{T,FC,SV,SM}
  m          :: Int
  n          :: Int
  p          :: Int
  ΔX         :: SM
  X          :: SM
  W          :: SM
  P          :: SM
  Q          :: SM
  C          :: SM
  D          :: SM
  V          :: Vector{SM}
  Z          :: Vector{SM}
  R          :: Vector{SM}
  H          :: Vector{SM}
  τ          :: Vector{SV}
  warm_start :: Bool
  stats      :: BlockGMRESStats{T}
end

function BlockGMRESSolver(m, n, p, memory, SV, SM)
  memory = min(div(n,p), memory)
  FC = eltype(SV)
  T  = real(FC)
  ΔX = SM(undef, 0, 0)
  X  = SM(undef, n, p)
  W  = SM(undef, n, p)
  P  = SM(undef, 0, 0)
  Q  = SM(undef, 0, 0)
  C  = SM(undef, p, p)
  D  = SM(undef, 2p, p)
  V  = SM[SM(undef, n, p) for i = 1 : memory]
  Z  = SM[SM(undef, p, p) for i = 1 : memory]
  R  = SM[SM(undef, p, p) for i = 1 : div(memory * (memory+1), 2)]
  H  = SM[SM(undef, 2p, p) for i = 1 : memory]
  τ  = SV[SV(undef, p) for i = 1 : memory]
  stats = BlockGMRESStats(0, false, T[], 0.0, "unknown")
  solver = BlockGMRESSolver{T,FC,SV,SM}(m, n, p, ΔX, X, W, P, Q, C, D, V, Z, R, H, τ, false, stats)
  return solver
end

function BlockGMRESSolver(A, B; memory::Int=5)
  m, n = size(A)
  s, p = size(B)
  SM = typeof(B)
  SV = matrix_to_vector(SM)
  BlockGMRESSolver(m, n, p, memory, SV, SM)
end

function warm_start!(solver :: BlockGMRESSolver, X0)
  n, p = size(solver. X)
  n2, p2 = size(X0)
  SM = typeof(solver.X)
  (n == n2 && p == p2) || error("X0 should have size ($n, $p)")
  solver.Δx = SM(undef, n, p)
  copyto!(solver.Δx, X0)
  solver.warm_start = true
  return solver
end

"""
    (X, stats) = block_gmres(A, B; X0::AbstractMatrix{FC}; memory::Int=20, M=I, N=I,
                             ldiv::Bool=false, restart::Bool=false, reorthogonalization::Bool=false,
                             atol::T = √eps(T), rtol::T=√eps(T), itmax::Int=0,
                             timemax::Float64=Inf, verbose::Int=0, history::Bool=false)

`T` is an `AbstractFloat` such as `Float32`, `Float64` or `BigFloat`.
`FC` is `T` or `Complex{T}`.

    (X, stats) = block_gmres(A, B, X0::AbstractVector; kwargs...)

GMRES can be warm-started from an initial guess `X0` where `kwargs` are the same keyword arguments as above.

Solve the linear system AX = B of size n with p right-hand sides using block-GMRES.

#### Input arguments

* `A`: a linear operator that models a matrix of dimension n;
* `B`: a matrix of size n × p.

#### Optional argument

* `X0`: a matrix of size n × p that represents an initial guess of the solution X.

#### Keyword arguments

* `memory`: if `restart = true`, the restarted version block-GMRES(k) is used with `k = memory`. If `restart = false`, the parameter `memory` should be used as a hint of the number of iterations to limit dynamic memory allocations. Additional storage will be allocated if the number of iterations exceeds `memory`;
* `M`: linear operator that models a nonsingular matrix of size `n` used for left preconditioning;
* `N`: linear operator that models a nonsingular matrix of size `n` used for right preconditioning;
* `ldiv`: define whether the preconditioners use `ldiv!` or `mul!`;
* `restart`: restart the method after `memory` iterations;
* `reorthogonalization`: reorthogonalize the new matrices of the block-Krylov basis against all previous matrix;
* `atol`: absolute stopping tolerance based on the residual norm;
* `rtol`: relative stopping tolerance based on the residual norm;
* `itmax`: the maximum number of iterations. If `itmax=0`, the default number of iterations is set to `2 * div(n,p)`;
* `timemax`: the time limit in seconds;
* `verbose`: additional details can be displayed if verbose mode is enabled (verbose > 0). Information will be displayed every `verbose` iterations;
* `history`: collect additional statistics on the run such as residual norms.

#### Output arguments

* `x`: a dense matrix of size n × p;
* `stats`: statistics collected on the run in a BlockGMRESStats.
"""
function block_gmres end

function block_gmres(A, B::AbstractMatrix{FC}, X0::AbstractMatrix{FC}; memory::Int=20, M=I, N=I,
                     ldiv::Bool=false, restart::Bool=false, reorthogonalization::Bool=false,
                     atol::T = √eps(T), rtol::T=√eps(T), itmax::Int=0,
                     timemax::Float64=Inf, verbose::Int=0, history::Bool=false) where {T <: AbstractFloat, FC <: FloatOrComplex{T}}

  start_time = time_ns()
  solver = BlockGMRESSolver(A, B; memory)
  warm_start!(solver, X0)
  elapsed_time = ktimer(start_time)
  timemax -= elapsed_time
  block_gmres!(solver, A, B; M, N, ldiv, restart, reorthogonalization, atol, rtol, itmax, timemax, verbose, history)
  solver.stats.timer += elapsed_time
  return solver.X, solver.stats
end

function block_gmres(A, B::AbstractMatrix{FC}; memory::Int=20, M=I, N=I,
                     ldiv::Bool=false, restart::Bool=false, reorthogonalization::Bool=false,
                     atol::T = √eps(T), rtol::T=√eps(T), itmax::Int=0,
                     timemax::Float64=Inf, verbose::Int=0, history::Bool=false) where {T <: AbstractFloat, FC <: FloatOrComplex{T}}

  start_time = time_ns()
  solver = BlockGMRESSolver(A, B; memory)
  elapsed_time = ktimer(start_time)
  timemax -= elapsed_time
  block_gmres!(solver, A, B; M, N, ldiv, restart, reorthogonalization, atol, rtol, itmax, timemax, verbose, history)
  solver.stats.timer += elapsed_time
  return solver.X, solver.stats
end

function block_gmres!(solver :: BlockGMRESSolver{T,FC,SV,SM}, A, B::AbstractMatrix{FC}, X0::AbstractMatrix{FC}; M=I, N=I,
                      ldiv::Bool=false, restart::Bool=false, reorthogonalization::Bool=false,
                      atol::T = √eps(T), rtol::T=√eps(T), itmax::Int=0,
                      timemax::Float64=Inf, verbose::Int=0, history::Bool=false) where {T <: AbstractFloat, FC <: FloatOrComplex{T}, SV <: AbstractVector{FC}, SM <: AbstractMatrix{FC}}

  start_time = time_ns()
  warm_start!(solver, X0)
  elapsed_time = ktimer(start_time)
  timemax -= elapsed_time
  block_gmres!(solver, A, B; M, N, ldiv, restart, reorthogonalization, atol, rtol, itmax, timemax, verbose, history)
  solver.stats.timer += elapsed_time
  return solver
end

function block_gmres!(solver :: BlockGMRESSolver{T,FC,SV,SM}, A, B::AbstractMatrix{FC}; M=I, N=I,
                      ldiv::Bool=false, restart::Bool=false, reorthogonalization::Bool=false,
                      atol::T = √eps(T), rtol::T=√eps(T), itmax::Int=0,
                      timemax::Float64=Inf, verbose::Int=0, history::Bool=false) where {T <: AbstractFloat, FC <: FloatOrComplex{T}, SV <: AbstractVector{FC}, SM <: AbstractMatrix{FC}}

  # Timer
  start_time = time_ns()
  timemax_ns = 1e9 * timemax

  n, m = size(A)
  s, p = size(B)
  m == n || error("System must be square")
  n == s || error("Inconsistent problem size")
  (verbose > 0) && @printf("BLOCK-GMRES: system of size %d with %d right-hand sides\n", n, p)

  # Check M = Iₙ and N = Iₙ
  MisI = (M === I)
  NisI = (N === I)

  # Check type consistency
  eltype(A) == FC || @warn "eltype(A) ≠ $FC. This could lead to errors or additional allocations in operator-matrix products."
  typeof(B) <: SM || error("ktypeof(B) is not a subtype of $SM")

  # Set up workspace.
  allocate_if(!MisI  , solver, :Q , SM, n, p)
  allocate_if(!NisI  , solver, :P , SM, n, p)
  allocate_if(restart, solver, :ΔX, SM, n, p)
  ΔX, X, W, V, Z = solver.ΔX, solver.X, solver.W, solver.V, solver.Z
  C, D, R, H, τ, stats = solver.C, solver.D, solver.R, solver.H, solver.τ, solver.stats
  warm_start = solver.warm_start
  RNorms = stats.residuals
  reset!(stats)
  Q  = MisI ? W : solver.Q
  R₀ = MisI ? W : solver.Q
  Xr = restart ? ΔX : X

  # Define the blocks D1 and D2
  D1 = view(D, 1:p, :)
  D2 = view(D, p+1:2p, :)

  # Coefficients for mul!
  α = -one(FC)
  β = one(FC)
  γ = one(FC)

  # Initial solution X₀.
  fill!(X, zero(FC))

  # Initial residual R₀.
  if warm_start
    mul!(W, A, Δx)
    W .= B .- W
    restart && (X .+= ΔX)
  else
    copyto!(W, B)
  end
  MisI || mulorldiv!(R₀, M, W, ldiv)  # R₀ = M(B - AX₀)
  RNorm = norm(R₀)                    # ‖R₀‖_F   

  history && push!(RNorms, RNorm)
  ε = atol + rtol * RNorm

  mem = length(V)  # Memory
  npass = 0        # Number of pass

  iter = 0        # Cumulative number of iterations
  inner_iter = 0  # Number of iterations in a pass

  itmax == 0 && (itmax = 2*div(n,p))
  inner_itmax = itmax

  (verbose > 0) && @printf("%5s  %5s  %7s  %5s\n", "pass", "k", "‖Rₖ‖", "timer")
  kdisplay(iter, verbose) && @printf("%5d  %5d  %7.1e  %.2fs\n", npass, iter, RNorm, ktimer(start_time))

  # Stopping criterion
  solved = RNorm ≤ ε
  tired = iter ≥ itmax
  inner_tired = inner_iter ≥ inner_itmax
  status = "unknown"
  overtimed = false

  while !(solved || tired || overtimed)

    # Initialize workspace.
    nr = 0  # Number of blocks Ψᵢⱼ stored in Rₖ.
    for i = 1 : mem
      fill!(V[i], zero(FC))  # Orthogonal basis of Kₖ(MAN, MR₀).
    end
    for Ψ in R
      fill!(Ψ, zero(FC))  # Upper triangular matrix Rₖ.
    end
    for block in Z
      fill!(block, zero(FC))  # Right-hand of the least squares problem min ‖Hₖ₊₁.ₖYₖ - ΓE₁‖₂.
    end

    if restart
      fill!(Xr, zero(FC))  # Xr === ΔX when restart is set to true
      if npass ≥ 1
        mul!(W, A, X)
        W .= B .- W
        MisI || mulorldiv!(R₀, M, W, ldiv)
      end
    end
    
    # Initial Γ and V₁
    copyto!(V[1], R₀)
    householder!(V[1], Z[1], τ[1])

    npass = npass + 1
    inner_iter = 0
    inner_tired = false

    while !(solved || inner_tired || overtimed)

      # Update iteration index
      inner_iter = inner_iter + 1

      # Update workspace if more storage is required and restart is set to false
      if !restart && (inner_iter > mem)
        for i = 1 : inner_iter
          push!(R, SM(undef, p, p))
        end
        push!(H, SM(undef, 2p, p))
        push!(τ, SV(undef, p))
      end

      # Continue the block-Arnoldi process.
      P = NisI ? V[inner_iter] : solver.P
      NisI || mulorldiv!(P, N, V[inner_iter], ldiv)  # P ← NVₖ
      mul!(W, A, P)                                  # W ← ANVₖ
      MisI || mulorldiv!(Q, M, W, ldiv)              # Q ← MANVₖ
      for i = 1 : inner_iter
        mul!(R[nr+i], V[i]', Q)       # Ψᵢₖ = Vᵢᴴ * Q
        mul!(Q, V[i], R[nr+i], α, β)  # Q = Q - Vᵢ * Ψᵢₖ
      end

      # Reorthogonalization of the block-Krylov basis.
      if reorthogonalization
        for i = 1 : inner_iter
          mul!(Ψtmp, V[i]', Q)       # Ψtmp = Vᵢᴴ * Q
          mul!(Q, V[i], Ψtmp, α, β)  # Q = Q - Vᵢ * Ψtmp
          R[nr+i] .+= Ψtmp
        end
      end

      # Vₖ₊₁ and Ψₖ₊₁.ₖ are stored in Q and C.
      householder!(Q, C, τ[inner_iter])

      # Update the QR factorization of Hₖ₊₁.ₖ.
      # Apply previous Householder reflections Ωᵢ.
      for i = 1 : inner_iter-1
        D1 .= R[nr+i]
        D2 .= R[nr+i+1]
        LAPACK.ormqr!('L', 'T', H[i], τ[i], D)
        R[nr+i] .= D1
        R[nr+i+1] .= D2
      end

      # Compute and apply current Householder reflection Ωₖ.
      H[inner_iter][1:p,:] .= R[nr+inner_iter]
      H[inner_iter][p+1:2p,:] .= C
      householder!(H[inner_iter], R[nr+inner_iter], τ[inner_iter], compact=true)

      # Update Zₖ = (Qₖ)ᴴΓE₁ = (Λ₁, ..., Λₖ, Λbarₖ₊₁)
      D1 .= Z[inner_iter]
      D2 .= zero(FC)
      LAPACK.ormqr!('L', 'T', H[inner_iter], τ[inner_iter], D)
      Z[inner_iter] .= D1

      # Update residual norm estimate.
      # ‖ M(B - AXₖ) ‖_F = ‖Λbarₖ₊₁‖_F
      C .= D2
      RNorm = norm(C)
      history && push!(RNorms, RNorm)

      # Update the number of coefficients in Rₖ
      nr = nr + inner_iter

      # Update stopping criterion.
      solved = RNorm ≤ ε
      inner_tired = restart ? inner_iter ≥ min(mem, inner_itmax) : inner_iter ≥ inner_itmax
      timer = time_ns() - start_time
      overtimed = timer > timemax_ns
      kdisplay(iter+inner_iter, verbose) && @printf("%5d  %5d  %7.1e  %.2fs\n", npass, iter+inner_iter, RNorm, ktimer(start_time))

      # Compute Vₖ₊₁.
      if !(solved || inner_tired || overtimed)
        if !restart && (inner_iter ≥ mem)
          push!(V, SM(undef, n, p))
          push!(Z, SM(undef, p, p))
        end
        copyto!(V[inner_iter+1], Q)
        Z[inner_iter+1] .= D2
      end
    end

    # Compute Yₖ by solving RₖYₖ = Zₖ with a backward substitution by block.
    Y = Z  # Yᵢ = Zᵢ
    for i = inner_iter : -1 : 1
      pos = nr + i - inner_iter         # position of Ψᵢ.ₖ
      for j = inner_iter : -1 : i+1
        mul!(Y[i], R[pos], Y[j], α, β)  # Yᵢ ← Yᵢ - ΨᵢⱼYⱼ
        pos = pos - j + 1               # position of Ψᵢ.ⱼ₋₁
      end
      ldiv!(UpperTriangular(R[pos]), Y[i])  # Yᵢ ← Yᵢ \ Ψᵢᵢ
    end

    # Form Xₖ = NVₖYₖ
    for i = 1 : inner_iter
      mul!(Xr, V[i], Y[i], γ, β)
    end
    if !NisI
      copyto!(solver.P, Xr)
      mulorldiv!(Xr, N, solver.P, ldiv)
    end
    restart && (X .+= Xr)

    # Update inner_itmax, iter, tired and overtimed variables.
    inner_itmax = inner_itmax - inner_iter
    iter = iter + inner_iter
    tired = iter ≥ itmax
    timer = time_ns() - start_time
    overtimed = timer > timemax_ns
  end
  (verbose > 0) && @printf("\n")

  # Termination status
  tired     && (status = "maximum number of iterations exceeded")
  solved    && (status = "solution good enough given atol and rtol")
  overtimed && (status = "time limit exceeded")

  # Update Xₖ
  warm_start && !restart && (X .+= ΔX)
  solver.warm_start = false

  # Update stats
  stats.niter = iter
  stats.solved = solved
  stats.timer = ktimer(start_time)
  stats.status = status
  return solver
end
