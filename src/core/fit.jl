using ProgressMeter
using Measurements

abstract type AbstractSpectrum <: Function end
params(::AbstractSpectrum) = error("not implemented")
param_names(s::AbstractSpectrum) = propertynames(s)
Base.length(sp::AbstractSpectrum) = length(params(sp))
Base.iterate(sp::AbstractSpectrum, i=1) = i > length(sp) ? nothing : (params(sp)[i], i + 1)
@inline (spectrum::AbstractSpectrum)(λ) = spectral_density(spectrum, λ)

abstract type AbstractModel end
guess(::AbstractModel, ::SeriesPoint) = error("not implemented")
constraints(::AbstractModel) = error("not implemented")
function apply_constraints!(params, model::AbstractModel)
    @inbounds @simd for i in eachindex(params)
        mi, ma = constraints(model)[i]
        params[i] = params[i] > ma ? ma : params[i] < mi ? mi : params[i]
    end
end
nparams(model::AbstractModel) = length(constraints(model))

using LinearAlgebra

function jacobian(spectrum::AbstractSpectrum, filter::Filter)
    return filter_flux(l -> gradient(spectrum, l), filter)
end
function weighted_jacobian!(J, spectrum::AbstractSpectrum, pt::SeriesPoint)
    @inbounds @simd for i in eachindex(pt.filters)
        J[:, i] .= jacobian(spectrum::AbstractSpectrum, pt.filters[i])  ./ pt.errs[i]
    end
end

struct LMResult{ST, MT, T}
    pt::SeriesPoint{T}
    spectrum::ST
    model::MT
    covar::Matrix{Float64}
    chi2::Float64
    converged::Bool
    iters::Int
end

Base.iterate(r::LMResult) = (r.spectrum, Val(:covar))
Base.iterate(r::LMResult, ::Val{:covar}) = (r.covar, Val(:chi2))
Base.iterate(r::LMResult, ::Val{:chi2}) = (chi2dof(r), Val(:conv))
Base.iterate(r::LMResult, ::Val{:conv}) = (r.converged, Val(:iters))
Base.iterate(r::LMResult, ::Val{:iters}) = (r.iters, Val(:end))
Base.iterate(::LMResult, ::Val{:end}) = nothing

chi2(r::LMResult) = r.chi2
chi2dof(r::LMResult) = r.chi2 / length(r.pt.filters)
nparams(r::LMResult) = length(r.spectrum)
residuals(r::LMResult) = filter_flux(r.spectrum, r.pt) - r.pt.vals
fit_summary(r::LMResult) = fit_summary(r.spectrum, r.pt)

function levenberg_marquardt(model, pt::SeriesPoint; tol = 1e-8, maxiter=1000, verbose=0)
    β = collect(guess(model, pt))
    newβ = similar(β)

    fr = filter_flux(spectrum(model, β), pt)
    fr_buffer = similar(fr)

    wJ = zeros(nparams(model), length(pt.filters))
    M = zeros(nparams(model), nparams(model))
    grad = similar(β)

    function step!(fr, β, lambda)
        # assume fr contains readings at β
        weighted_jacobian!(wJ, spectrum(model, β), pt)
        mul!(M, wJ, wJ')
        @inbounds @simd for i in 1:nparams(model)
            M[i, i] += lambda
        end
        mul!(grad, wJ, (pt.vals .- fr) ./ pt.errs)
        verbose > 1 && begin
            @show M
            @show wJ
            @show grad
            @show lambda
            println()
        end
        ldiv!(newβ, lu(M), grad)
        @. newβ += β
        apply_constraints!(newβ, model)
        return newβ
    end
    _chi2(_fr) = sum(((y1, y2, err),) -> ((y1 - y2) / err)^2, zip(pt.vals, _fr, pt.errs))

    weighted_jacobian!(wJ, spectrum(model, β), pt)
    λ₀ = maximum(abs, wJ)^2 * 1e4
    λ = λ₀
    old_chi2 = _chi2(fr)
    step!(fr, β, λ)
    filter_flux!(fr_buffer, spectrum(model, β), pt)
    new_chi2 = _chi2(fr_buffer)

    converged = false
    iters = 1
    while iters < maxiter && !converged
        # check convergence
        d = sum(@. abs(β - newβ) / max(β, 1))
        if d < tol
            converged = true
            break
        end

        # adjust damping
        verbose > 0 && (println("iteration #$iters:"); @show β)
        rho = (old_chi2 - new_chi2) / sum(abs2, wJ' * (newβ - β))
        if rho < 5e-2 && λ < λ₀ * 1e16
            # Bad step, increase damping and repeat
            λ *= 10
        else
            λ *= 0.3
            old_chi2 = new_chi2
            verbose > 0 && (@show rho; @show newβ; @show new_chi2; println())

            # prepare for new step
            β, newβ = newβ, β
            fr, fr_buffer = fr_buffer, fr
        end
        step!(fr, β, λ)
        filter_flux!(fr_buffer, spectrum(model, newβ), pt)
        new_chi2 = _chi2(fr_buffer)
        iters += 1
    end
    out_spec = spectrum(model, newβ)
    weighted_jacobian!(wJ, out_spec, pt)
    return LMResult(
        pt,
        out_spec,
        model,
        inv(wJ * wJ') * 2,
        new_chi2,
        converged,
        iters)
end

struct FitSeries{ST, MT, T}
    timestamps::Vector{T}
    fitresults::Vector{LMResult{ST, MT, T}}
    param_measurements::Vector{Vector{Measurement{T}}}
end
function Base.copy(fs::FitSeries)
    FitSeries(
        copy(fs.timestamps),
        copy(fs.param_measurements),
        [copy(meas) for meas in fs.param_measurements]
    )
end

function fit(ser::PhotometryData, model, times=time_domain(ser);
        filter=true, threshold=Inf, kw...)
    fits = @showprogress[levenberg_marquardt(model, ser(t); kw...) for t in times]
    meas = [Measurement{Float64}[] for _ in 1:nparams(model)]
    for fit in fits
        vs = Measurements.correlated_values(collect(Float64, fit.spectrum), fit.covar)
        @simd for i in 1:nparams(model)
            push!(meas[i], vs[i])
        end
    end
    fser = FitSeries(times, fits, meas)
    if filter
        return filter!(chi2dof_threshold(threshold), fser)
    else return fser
    end
end
function Base.filter!(f, fser::FitSeries)
    inds = findall(!f, fser.fitresults)
    deleteat!(fser.timestamps, inds)
    deleteat!(fser.fitresults, inds)
    for i in 1:nparams(first(fser.fitresults))
        deleteat!(fser.param_measurements[i], inds)
    end
    return fser
end
Base.filter(f, fser::FitSeries) =
    filter!(f, copy(fser))
chi2dof_threshold(th) = res -> res.converged && chi2dof(res) < th

function Base.getindex(fser::FitSeries; t)
    i = findmin(_t -> abs(_t - t), fser.timestamps)[2]
    return fser[i]
end
Base.getindex(fser::FitSeries, i::Int) = fser.fitresults[i]

function Base.getproperty(fser::FitSeries{ST}, param::Symbol) where ST
    param in fieldnames(typeof(fser)) && return getfield(fser, param)
    param_index = findfirst(==(param), param_names(first(fser.fitresults).spectrum))
    if param_index !== nothing
        return fser.param_measurements[param_index]
    end
    return getfield(fser, param)
end
