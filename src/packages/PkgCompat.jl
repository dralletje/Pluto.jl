module PkgCompat

export package_versions, package_completions

import Pkg
import Pkg.Types: VersionRange

# Should be in Base
flatmap(args...) = vcat(map(args...)...)

# Should be in Base
function select(f::Function, xs)
	for x ∈ xs
		if f(x)
			return x
		end
	end
	error("Not found")
end


###
# CONTEXT
###

# struct Unsupported end

# const pkg_supports_context = isdefined(Pkg, :Types) && isdefined(Pkg.Types, :Context)
# const PkgInternalContext = pkg_supports_context ? Pkg.Types.Context : Unsupported


# ✅ Public API
@Base.@kwdef struct PkgContext
	dir::String=mktempdir()
end

function in_context(f::Function, ctx::PkgContext)
	old = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = ctx.dir
    try
        f()
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

function wrap_context(f::Function)
	return function(ctx::PkgContext, args...; kwargs...)
		in_context(ctx) do
			f(args...; kwargs...)
		end
	end
end

const dependencies = wrap_context(Pkg.dependencies)
const project = wrap_context(Pkg.project)
const add = wrap_context(Pkg.add)
const rm = wrap_context(Pkg.rm)
const resolve = wrap_context(Pkg.resolve)
const instantiate = wrap_context(Pkg.instantiate)
const precompile = wrap_context(Pkg.precompile)
const status = wrap_context(Pkg.status)


# ⛔️ Internal API
# create_empty_ctx()::Pkg.Types.Context = Pkg.Types.Context(env=Pkg.Types.EnvCache(joinpath(mktempdir(),"Project.toml")))


# ✅ Public API
create_empty_ctx()::PkgContext = PkgContext()

# ⚠️ Internal API with fallback
function mark_original!(ctx::Pkg.Types.Context)
	try
		ctx.env.original_project = deepcopy(ctx.env.project)
		ctx.env.original_manifest = deepcopy(ctx.env.manifest)
	catch e
		@error "Pkg compat: failed to set original_project" exception=(e,catch_backtrace())
	end
end

mark_original!(ctx::PkgContext) = nothing


env_dir(ctx::Pkg.Types.Context) = dirname(ctx.env.project_file)
env_dir(ctx::PkgContext) = ctx.dir


###
# REGISTRIES
###

# (⛔️ Internal API)
"Return paths to all installed registries."
_get_registry_paths() = @static if isdefined(Pkg.Types, :registries)
	Pkg.Types.registries()
else
	registry_specs = Pkg.Types.collect_registries()
	[s.path for s in registry_specs]
end

# (⛔️ Internal API)
_get_registries() = map(_get_registry_paths()) do r
	r => Pkg.Types.read_registry(joinpath(r, "Registry.toml"))
end

# (⛔️ Internal API)
"Contains all registries as `Pkg.Types.Registry` structs."
const _parsed_registries = Ref(_get_registries())

# (⛔️ Internal API)
"Re-parse the installed registries from disk."
function refresh_registry_cache()
	_parsed_registries[] = _get_registries()
end

# (⚠️ Internal API with fallback)
_stdlibs() = try
	values(Pkg.Types.stdlibs())
catch e
	@error "Pkg compat: failed to load standard libraries." exception=(e,catch_backtrace())

	String["CRC32c", "Future", "Sockets", "MbedTLS_jll", "Random", "ArgTools", "libLLVM_jll", "GMP_jll", "Pkg", "Serialization", "LibSSH2_jll", "SHA", "OpenBLAS_jll", "REPL", "LibUV_jll", "nghttp2_jll", "Unicode", "Profile", "SparseArrays", "LazyArtifacts", "CompilerSupportLibraries_jll", "Base64", "Artifacts", "PCRE2_jll", "Printf", "p7zip_jll", "UUIDs", "Markdown", "TOML", "OpenLibm_jll", "Test", "MPFR_jll", "Mmap", "SuiteSparse", "LibGit2", "LinearAlgebra", "Logging", "NetworkOptions", "LibGit2_jll", "LibOSXUnwind_jll", "Dates", "LibUnwind_jll", "Libdl", "LibCURL_jll", "dSFMT_jll", "Distributed", "InteractiveUtils", "Downloads", "SharedArrays", "SuiteSparse_jll", "LibCURL", "Statistics", "Zlib_jll", "FileWatching", "DelimitedFiles", "Tar", "MozillaCACerts_jll"]
end

# ⚠️ Internal API with fallback
is_stdlib(package_name::AbstractString) = package_name ∈ _stdlibs()

# (⚠️ Internal API with fallback)
global_ctx = try
	Pkg.Types.Context()
catch
	nothing
end

###
# Package names
###

# ⚠️ Internal API with fallback
function package_completions(partial_name::AbstractString)::Vector{String}
	String[
		filter(s -> startswith(s, partial_name), collect(_stdlibs()));
		_registered_package_completions(partial_name)
	]
end

# (⚠️ Internal API with fallback)
function _registered_package_completions(partial_name::AbstractString)::Vector{String}
	# compat
	try
		@static if hasmethod(Pkg.REPLMode.complete_remote_package, (String,))
			Pkg.REPLMode.complete_remote_package(partial_name)
		else
			Pkg.REPLMode.complete_remote_package(partial_name, 1, length(partial_name))[1]
		end
	catch e
		@error "Pkg compat: failed to autocomplete packages" exception=(e,catch_backtrace())
		String[]
	end
end

###
# Package versions
###

# (⛔️ Internal API)
"""
Return paths to all found registry entries of a given package name.

# Example
```julia
julia> Pluto.PkgCompat._registry_entries("Pluto")
1-element Vector{String}:
 "/Users/fons/.julia/registries/General/P/Pluto"
```
"""
function _registry_entries(package_name::AbstractString, registries::Vector=_parsed_registries[])::Vector{String}
	flatmap(registries) do (rpath, r)
		packages = values(r["packages"])
		String[
			joinpath(rpath, d["path"])
			for d in packages
			if d["name"] == package_name
		]
	end
end

# (⛔️ Internal API)
function _package_versions_from_path(registry_entry_fullpath::AbstractString)::Vector{VersionNumber}
	# compat
    (@static if hasmethod(Pkg.Operations.load_versions, (String,))
        Pkg.Operations.load_versions(registry_entry_fullpath)
    else
        Pkg.Operations.load_versions(global_ctx, registry_entry_fullpath)
    end) |> keys |> collect |> sort!
end

# ⚠️ Internal API with fallback
"""
Return all registered versions of the given package. Returns `["stdlib"]` for standard libraries, and a `Vector{VersionNumber}` for registered packages.
"""
function package_versions(package_name::AbstractString)::Vector
    if is_stdlib(package_name)
        ["stdlib"]
    else
		try
			ps = _registry_entries(package_name)
			flatmap(_package_versions_from_path, ps)
		catch e
			@error "Pkg compat: failed to get installable versions." exception=(e,catch_backtrace())
			[]
		end
    end
end

# ⚠️ Internal API with fallback
"Does a package with this name exist in one of the installed registries?"
package_exists(package_name::AbstractString)::Bool =
    package_versions(package_name) |> !isempty



# ✅ Public API
"Find a package in the manifest."
_get_manifest_entry(ctx::PkgContext, package_name::AbstractString) = 
    select(e -> e.name == package_name, values(dependencies(ctx)))

# ⚠️✅ Internal API with fallback
function get_manifest_version(ctx::PkgContext, package_name)
    if is_stdlib(package_name)
        "stdlib"
    else
        entry = _get_manifest_entry(ctx, package_name)
        entry.version
    end
end

###
# WRITING COMPAT ENTRIES
###


# ⛔️ Internal API
function write_semver_compat_entries!(ctx::Pkg.Types.Context)
    for p in keys(Pkg.project(ctx).dependencies)
        if !haskey(ctx.env.project.compat, p)
            entry = select(e -> e.name == p, values(ctx.env.manifest))
            if entry.version !== nothing
                ctx.env.project.compat[p] = "^" * string(entry.version)
            end
        end
    end
    Pkg.Types.write_env(ctx.env)
end


# ⛔️ Internal API
function clear_semver_compat_entries!(ctx::Pkg.Types.Context)
    for p in keys(ctx.env.project.compat)
        entry = select(e -> e.name == p, values(ctx.env.manifest))
        if entry.version !== nothing
            if ctx.env.project.compat[p] == "^" * string(entry.version)
                delete!(ctx.env.project.compat, p)
            end
        end
    end
    Pkg.Types.write_env(ctx.env)
end




end