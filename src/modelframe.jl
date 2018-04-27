"""
Wrapper which combines Formula (Terms) and an AbstractDataFrame

This wrapper encapsulates all the information that's required to transform data
of the same structure as the wrapped data frame into a model matrix.  This goes
above and beyond what's expressed in the `Formula` itself, for instance
including information on how each categorical variable should be coded.

Creating a `ModelFrame` first parses the `Formula` into `Terms`, checks which
variables are categorical and determines the appropriate contrasts to use, and
then creates the necessary contrasts matrices and stores the results.

# Constructors

```julia
ModelFrame(f::Formula, df::AbstractDataFrame; contrasts::Dict = Dict())
ModelFrame(ex::Expr, d::AbstractDataFrame; contrasts::Dict = Dict())
ModelFrame(terms::Terms, df::AbstractDataFrame; contrasts::Dict = Dict())
# Inner constructors:
ModelFrame(df::AbstractDataFrame, terms::Terms, missing::BitArray)
ModelFrame(df::AbstractDataFrame, terms::Terms, missing::BitArray, contrasts::Dict{Symbol, ContrastsMatrix})
```

# Arguments

* `f::Formula`: Formula whose left hand side is the *response* and right hand
  side are the *predictors*.
* `df::AbstractDataFrame`: The data being modeled.  This is used at this stage
  to determine which variables are categorical, and otherwise held for
  [`ModelMatrix`](@ref).
* `contrasts::Dict`: An optional Dict of contrast codings for each categorical
  variable.  Any unspecified variables will have [`DummyCoding`](@ref).  As a
  keyword argument, these can be either instances of a subtype of
  [`AbstractContrasts`](@ref), or a [`ContrastsMatrix`](@ref).  For the inner
  constructor, they must be [`ContrastsMatrix`](@ref)es.
* `ex::Expr`: An expression which will be converted into a `Formula`.
* `terms::Terms`: For inner constructor, the parsed `Terms` from the `Formula`.
* `missing::BitArray`: For inner constructor, indicates whether each row of `df`
  contains any missing data.

# Examples

```julia
julia> df = DataFrame(x = 1:4, y = 5:9)
julia> mf = ModelFrame(y ~ 1 + x, df)
```

"""
mutable struct ModelFrame
    dt::Data.Table
    terms::Terms
    msng::BitArray
    ## mapping from df keys to contrasts matrices
    contrasts::Dict{Symbol, ContrastsMatrix}
end

is_categorical(::AbstractArray{<:Union{Missing, Real}}) = false
is_categorical(::AbstractArray) = true

## Check for non-redundancy of columns.  For instance, if x is a factor with two
## levels, it should be expanded into two columns in y~0+x but only one column
## in y~1+x.  The default is the rank-reduced form (contrasts for n levels only
## produce n-1 columns).  In general, an evaluation term x within a term
## x&y&... needs to be "promoted" to full rank if y&... hasn't already been
## included (either explicitly in the Terms or implicitly by promoting another
## term like z in z&y&...).
##
## This modifies the Terms, setting `trms.is_non_redundant = true` for all non-
## redundant evaluation terms.
function check_non_redundancy!(trms::Terms, d::Data.Table)

    (n_eterms, n_terms) = size(trms.factors)

    encountered_columns = Vector{eltype(trms.factors)}[]

    if trms.intercept
        push!(encountered_columns, zeros(eltype(trms.factors), n_eterms))
    end

    for i_term in 1:n_terms
        for i_eterm in 1:n_eterms
            ## only need to check eterms that are included and can be promoted
            ## (e.g., categorical variables that expand to multiple mm columns)
            if Bool(trms.factors[i_eterm, i_term]) && is_categorical(d[trms.eterms[i_eterm]])
                dropped = trms.factors[:,i_term]
                dropped[i_eterm] = 0

                if dropped ∉ encountered_columns
                    trms.is_non_redundant[i_eterm, i_term] = true
                    push!(encountered_columns, dropped)
                end

            end
        end
        ## once we've checked all the eterms in this term, add it to the list
        ## of encountered terms/columns
        push!(encountered_columns, view(trms.factors, :, i_term))
    end

    return trms.is_non_redundant
end

const DEFAULT_CONTRASTS = DummyCoding

# get unique values, honoring levels order
_unique(x::AbstractCategoricalArray) = intersect(levels(x), unique(x))
_unique(x::AbstractCategoricalArray{T}) where {T>:Missing} =
    convert(Array{Missings.T(T)}, filter!(!ismissing, intersect(levels(x), unique(x))))

function _unique(x::AbstractArray{T}) where T
    levs = T >: Missing ?
           convert(Array{Missings.T(T)}, filter!(!ismissing, unique(x))) :
           unique(x)
    try; sort!(levs); end
    return levs
end

## Set up contrasts:
## Combine actual DF columns and contrast types if necessary to compute the
## actual contrasts matrices, levels, and term names (using DummyCoding
## as the default)
function evalcontrasts(d::Data.Table, contrasts::Dict = Dict())
    evaledContrasts = Dict()
    for (term, col) in zip(fieldnames(d), d)
        is_categorical(col) || continue
        evaledContrasts[term] = ContrastsMatrix(haskey(contrasts, term) ?
                                                contrasts[term] :
                                                DEFAULT_CONTRASTS(),
                                                _unique(col))
    end
    return evaledContrasts
end


## copied from DataFrames:
function _nonmissing!(res, col)
    # workaround until JuliaLang/julia#21256 is fixed
    eltype(col) >: Missing || return
    
    @inbounds for (i, el) in enumerate(col)
        res[i] &= !ismissing(el)
    end
end

function _nonmissing!(res, col::CategoricalArray{>: Missing})
    for (i, el) in enumerate(col.refs)
        res[i] &= el > 0
    end
end

# handle some inconsistencies between how named tuples are constructed
if isdefined(Core, :NamedTuple)
    _select(d::Data.Table, cols::NTuple{N,Symbol} where N) = NamedTuple{cols}(d)
    _filter(d::T, rows) where T<:Data.Table = T(([col[rows] for col in d]...))
else
    _select(d::Data.Table, cols::NTuple{N,Symbol} where N) = d[cols]
    _filter(d::T, rows) where T<:Data.Table = T([col[rows] for col in d]...)
end

_size(d::Data.Table) = size(Data.schema(d))
_size(d::Data.Table, dim::Int) = size(Data.schema(d), dim)

## Default NULL handler.  Others can be added as keyword arguments
function missing_omit(d::T) where T<:Data.Table
    nonmissings = trues(_size(d, 1))
    for col in d
        _nonmissing!(nonmissings, col)
    end
    _filter(d, nonmissings), nonmissings
end

_droplevels!(x::Any) = x
_droplevels!(x::AbstractCategoricalArray) = droplevels!(x)

function ModelFrame(trms::Terms, d::Data.Table;
                    contrasts::Dict = Dict())
    d, msng = missing_omit(_select(d, (Symbol.(trms.eterms)...)))

    evaledContrasts = evalcontrasts(d, contrasts)

    ## Check for non-redundant terms, modifying terms in place
    check_non_redundancy!(trms, d)

    ModelFrame(d, trms, msng, evaledContrasts)
end

ModelFrame(f::Formula, d; kwargs...) = ModelFrame(Terms(f), d; kwargs...)
ModelFrame(ex::Expr, d; kwargs...) = ModelFrame(Formula(ex), d; kwargs...)
ModelFrame(t::Terms, d; kwargs...) = ModelFrame(t, Data.stream!(d, Data.Table); kwargs...)

## TODO: remove thes untested constructors?
ModelFrame(d, term::Terms, msng::BitArray) = ModelFrame(Data.stream!(d, Data.Table), term, msng)
ModelFrame(df::Data.Table, term::Terms, msng::BitArray) = ModelFrame(df, term, msng, evalcontrasts(df)) 


"""
    setcontrasts!(mf::ModelFrame, new_contrasts::Dict)

Modify the contrast coding system of a ModelFrame in place.
"""
function setcontrasts!(mf::ModelFrame, new_contrasts::Dict)
    for (col, contr) in new_contrasts
        haskey(mf.dt, col) || continue
        mf.contrasts[col] = ContrastsMatrix(contr, _unique(mf.dt[col]))
    end
    return mf
end
setcontrasts!(mf::ModelFrame; kwargs...) = setcontrasts!(mf, Dict(kwargs))

"""
    StatsBase.model_response(mf::ModelFrame)
Extract the response column, if present.  `DataVector` or
`PooledDataVector` columns are converted to `Array`s
"""
function StatsBase.model_response(mf::ModelFrame)
    if mf.terms.response
        _response = mf.dt[mf.terms.eterms[1]]
        T = Missings.T(eltype(_response))
        convert(Array{T}, _response)
    else
        error("Model formula one-sided")
    end
end


"""
    termnames(term::Symbol, col)
Returns a vector of strings with the names of the coefficients
associated with a term.  If the column corresponding to the term
is not categorical, a one-element vector is returned.
"""
termnames(term::Symbol, col) = [string(term)]
function termnames(term::Symbol, mf::ModelFrame; non_redundant::Bool = false)
    if haskey(mf.contrasts, term)
        termnames(term, mf.dt[term],
                  non_redundant ?
                  convert(ContrastsMatrix{FullDummyCoding}, mf.contrasts[term]) :
                  mf.contrasts[term])
    else
        termnames(term, mf.dt[term])
    end
end

termnames(term::Symbol, col::Any, contrast::ContrastsMatrix) =
    ["$term: $name" for name in contrast.termnames]


function expandtermnames(term::Vector)
    if length(term) == 1
        return term[1]
    else
        return foldr((a,b) -> vec([string(lev1, " & ", lev2) for
                                   lev1 in a,
                                   lev2 in b]),
                     term)
    end
end


"""
    coefnames(mf::ModelFrame)
Returns a vector of coefficient names constructed from the Terms
member and the types of the evaluation columns.
"""
function StatsBase.coefnames(mf::ModelFrame)
    terms = droprandomeffects(dropresponse!(mf.terms))

    ## strategy mirrors ModelMatrx constructor:
    eterm_names = Dict{Tuple{Symbol,Bool}, Vector{String}}()
    term_names = Vector{Vector{String}}()

    if terms.intercept
        push!(term_names, String["(Intercept)"])
    end

    factors = terms.factors

    for (i_term, term) in enumerate(terms.terms)

        ## names for columns for eval terms
        names = Vector{Vector{String}}()

        ff = view(factors, :, i_term)
        eterms = view(terms.eterms, ff)
        non_redundants = view(terms.is_non_redundant, ff, i_term)

        for (et, nr) in zip(eterms, non_redundants)
            if !haskey(eterm_names, (et, nr))
                eterm_names[(et, nr)] = termnames(et, mf, non_redundant=nr)
            end
            push!(names, eterm_names[(et, nr)])
        end
        push!(term_names, expandtermnames(names))
    end

    reduce(vcat, Vector{String}(), term_names)
end
