# Architecture

## Zero-by-default repository contract

The ordinary repository does not depend on Mix Workspace Ops and never reads a
registry. The portfolio registry is supplied to the operator tool, while the
repository's existing `mix.exs` remains the compatibility authority.

A project with no locally switchable cross-repository dependency requires no
MWO file or code. A project that does have one requires only the small Mix-load
dependency seam, because Mix evaluates dependency tuples before an external
task can alter them. Repository-local MWO configuration is absent by default;
an exceptional repository may have at most one declarative, schema-validated
manifest when its behavior cannot be derived from Mix metadata and the
portfolio registry.

Workspace runners, release projectors, acceptance harnesses, and provisioning
systems consume stable launch or receipt contracts later. They do not parse the
portfolio registry or incorporate MWO's implementation.

Mix evaluates dependencies while loading `mix.exs`, before an external Mix task
can inject a workspace-wide source policy. Mix Workspace Ops addresses that
bootstrap limitation with a small, versioned bootstrap materialized in operator
state and an explicit operator-generated data overlay. The bootstrap is passed
by path only to the launched Mix process; it is not copied into every repository.

A caller-supplied registry contains stable repository and project coordinates
only. Dependency edges are derived from current Mix metadata; they are never
copied into the registry.

## The Mix-load seam

The seam is one function call per cross-repository dependency:

```elixir
if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

@compile {:no_warn_undefined, MixWorkspaceOpsBootstrap}

defp deps do
  [
    workspace_dep(:example_core, "~> 1.0"),
    workspace_dep(:example_edge, [github: "example-org/example_edge", branch: "main"],
      only: [:dev, :test]
    )
  ]
end

defp workspace_dep(app, committed_default, extra_opts \\ []) do
  if Code.ensure_loaded?(MixWorkspaceOpsBootstrap) do
    MixWorkspaceOpsBootstrap.dep(app, committed_default, __DIR__, extra_opts)
  else
    committed_dep(app, committed_default, extra_opts)
  end
end

defp committed_dep(app, requirement, []) when is_binary(requirement), do: {app, requirement}

defp committed_dep(app, requirement, opts) when is_binary(requirement),
  do: {app, requirement, opts}

defp committed_dep(app, coordinates, opts) when is_list(coordinates),
  do: {app, Keyword.merge(coordinates, opts)}
```

The first line goes above the `MixProject` module and the rest goes inside it.
That line is load-bearing: the bootstrap is an `.exs` file materialized in
operator state and named by `MIX_WORKSPACE_OPS_BOOTSTRAP`, so nothing else puts
`MixWorkspaceOpsBootstrap` on the code path. A `mix.exs` that only asks whether
the module is loaded always gets `false`, resolves nothing, and looks wired
while doing it.

The second argument is the **committed default**: what this repository resolves
to with nothing else active, and it is committed to the repository rather than
supplied by a tool. A binary is a Hex requirement. A keyword list carrying
`:github` is committed git coordinates, and a dependency with no Hex release
needs that form — otherwise a fresh clone, and any consumer of the published
package, has nowhere to resolve it from. The seam has no catalog, so the
committed default is how a repository states its own answer.

The third argument carries the dependency's own Mix options, and both branches
carry them. `only:`, `optional:`, `runtime:` and `targets:` decide whether a
dependency exists at this call site at all, which is `mix.exs`'s to say, so they
travel with the call and are not dropped when no overlay is active. `override:`
is a resolution fact and comes from the catalog on the overlay path.

With an overlay carrying the application, the overlay row decides instead, and
the row states which of `local`, `github` or `hex` the operator's resolution
chose along with everything the tuple needs:

```
app 	 local  	 <absolute path> 	 <revision> 	 <source digest> 	 <opts>
app 	 github 	 <owner/repo>    	 <branch|ref|tag|-> 	 <value|-> 	 <subdir|-> 	 <opts>
app 	 hex    	 <requirement>   	 <opts>
```

The emitted tuple is `{app, [path: ...]}`, `{app, [github: ...]}`, or
`{app, requirement}` — with the dependency's Mix options merged in, and
call-site options winning over them. A path or git dependency carries no
requirement, because Mix takes none there.

### The committed default is what publish resolution produces

With an overlay the published requirement comes from the catalog; with none it
comes from the committed default in `mix.exs`. Both are correct on their own
terms, and nothing was reconciling them, so one application could carry two
published requirements that disagree.

> **The committed default is the tuple publish resolution would produce, options
> included.**

That is what a committed default is *for*. A fresh clone and a consumer of the
published package both have to resolve without this tool — from Hex, or from git
where there is no Hex release — and that is exactly the question publish
resolution answers. Stating the rule makes the two authorities checkable against
each other instead of merely coexisting.

`mwo seam --project ID --registry PATH --checkout-root PATH` makes it
mechanical. It resolves the project in publish mode and prints the `deps/0` the
seam implies, one `workspace_dep/3` call per managed dependency, ready to paste:

```bash
./mix_workspace_ops seam \
  --registry /path/to/registry.json \
  --checkout-root /path/to/checkouts \
  --project example.consumer
```

`only:`, `optional:`, `runtime:` and `targets:` are printed as the call's own
options, because they say whether the dependency exists at that call site.
`override:` is not: it is a resolution fact and belongs to the catalog. A
declaration whose publish order resolves to a local checkout has no committed
default — a path cannot be published — and is refused by name.

### `mix deps.sources`

The bootstrap defines one Mix task, `mix deps.sources`, which prints where every
managed dependency in the current project resolved from. It reports what the
seam actually emitted rather than deriving it a second time, so the answer is
what Mix was given.

The task costs a repository nothing. The bootstrap is already loaded into the
Mix process by path, so defining the task there installs no file, adds no
`mix.exs` line, and adds no dependency. It exists inside a checkout, from inside
Mix, which `mwo sources` cannot be: that needs the escript, a catalog, a checkout
root and a binding.

Publication is fail-closed at the seam. An overlay decided for ordinary
development names a developer's checkouts, so a publishing task running under
one is refused rather than allowed to put a local path into a released
package. An overlay decided under publish resolution is used, because that is
what publication should resolve against.

The operator tool is separate from registry ownership, package projection,
workspace impact scheduling, and product acceptance. Its source tree contains
only protocols, mechanisms, and synthetic fixtures, so another ecosystem can
adopt it without inheriting the original operator's repository graph.

Portable registry identity is resolved by an explicit checkout-root binding.
The binder requires the conventional repository basename, the expected GitHub
identity, a real Git root, and an independent Git common directory. Exceptional
layouts require an explicit untracked binding file.

The resulting source overlay is content-addressed beneath operator-owned XDG
state. The tool provides its absolute path only to the process it launches via
`MIX_WORKSPACE_OPS_OVERLAY`; the minimal project bootstrap never scans ancestors,
reads shell profiles, or falls back to other source-selection variables.

Overlay integrity and semantic source context are distinct. The overlay digest
protects exact bytes and necessarily reflects local absolute paths. The context
digest excludes those paths, raw registry formatting, and target-repository
source dirt. It includes resolved identities/graph, source mode,
same-repository source identities, external revisions/content, lock state, and
the toolchain. A cache-aware delegated runner consumes that digest as one opaque
cache component without parsing an overlay or the portfolio registry.

Managed activation allocates content-addressed operator state for dependencies,
builds, Hex data, and an overlay-specific lockfile. Delegated activation omits
those variables because the launched workspace runner owns its independent
child state. Both modes carry the same source/bootstrap contract.

Non-application workspace roots, including ordinary umbrella roots, are valid
registry targets. No fake app name is introduced for a tooling or umbrella root.

## The catalog contract

The catalog is data. It is validated from outside, by this tool, and never
contains executable code, credentials, absolute paths, or machine-local
directory names.

A repository is the unit of the catalog. Every repository carries the identity
an operation needs — remote coordinate, default branch, languages, lifecycle,
disposition, visibility, roles, groups, and agent scope — whether or not it
builds anything with Mix. `languages` is a list, because one repository may
carry several toolchains, and Mix data is an optional block, so a repository
with no Mix project is still catalogued, grouped, and selected by a
repository-scoped view.

`disposition` describes the remote repository — `tracked`, `superseded`,
`archived`, `intentionally_untracked`. Machine-local observations such as
worktrees, scratch clones, and generated checkouts belong in an operator-local
ledger, never in the catalog.

### Dependency sources

A repository's `dependency_sources` table says how each application it consumes
can be resolved. It is a resolution table, not a dependency list: `mix.exs`
remains the authority for which dependencies exist and what versions they
require.

Every entry resolves through an ordered list of candidate sources. The default
order is `local`, then `github`, then `hex`, and the common case declares no
order at all. An entry may declare one where it genuinely differs — a package
with no published release names `["local", "github"]`, a third-party package
with no sibling checkout names `["hex"]`. `publish_order` works the same way and
defaults to `hex` alone, but an entry whose source will never be on a package
registry may name another source, and publishing then honours it.

`local` carries no path. It is derived from the catalog identity of the project
that provides the application, joined to the operator's checkout of that
project's repository. That is what keeps machine-local layout out of the
catalog: a relative sibling path is a fact about one operator's disk, while the
provider's repository and project path are portable.

An entry may also carry `opts` — the Mix dependency options merged into the
emitted tuple, from a fixed vocabulary of `override`, `runtime`, `optional`,
`only`, and `targets`. These change how Mix resolves a diamond, so dropping them
changes behaviour and they are carried explicitly.

A project inside the repository may declare its own entry for one application,
which replaces the repository's entry for that application alone.

### Application identity and provider selection

Application identity and provider selection are separate concepts. A project
declares what it `provides`. More than one project may provide one application —
a fork, an example, a successor, a vendored copy — and that is legal identity,
not a defect. It becomes an error only where a dependency declaration would have
to choose between candidates without saying which, and the error names every
candidate. A declaration resolves the choice with `provider`, naming one
project. Nothing ever silently takes the first match.

### Workspace membership

Workspace membership has one authority: derivation. A Mix umbrella declares its
members through `apps_path`; a Blitz workspace declares them through project
globs in the root project's metadata. The catalog records which mechanism a
repository uses, and records members only as exceptions — a project derivation
would include but which is not a member, or one it misses. Generated output that
happens to be a Mix project is catalogued with the `generated` kind and is never
a workspace member.

### Release chain

Membership of the release train is declared: a package is in the train when the
repository providing it lists the package in `release_chain`. Prerequisites are
then derived from the dependency-source declarations wherever derivation can see
them. A cross-repository edge is visible, because a repository's table names what
it consumes from elsewhere. An edge between two packages of the same repository
is not, because a repository-scoped table does not say which of its projects
consumes an entry; that edge is recorded explicitly, or the consuming project
declares its own table and restores the attribution.

### Views

A view selects repositories first and projects second. Repository-scoped
selection is what makes a repository with no Mix project reachable. A v2
selector matches on `groups_any`, `groups_all`, `languages`, `lifecycles`,
`repository_ids`, and `exclude_repository_ids`, then narrows to projects with
`project_ids` and `exclude_project_ids`.

### Schema versions

`portfolio_registry.registry/v2` and `portfolio_registry.view/v2` are current.
`mix_workspace_ops.registry/v1` and `mix_workspace_ops.view/v1` still load and
are normalized onto the same records, so a v1 catalog keeps working while it is
migrated. A v1 document is treated as a single-language Elixir catalog with
every repository `tracked`, `active`, and `public`, and its project tags become
repository groups.

Registry discovery is an evidence-producing operation, not an authority by
itself. It only admits independent canonical Git roots for an explicitly named
owner. Real Mix metadata supplies application identity. Duplicate applications
and projects that cannot load are emitted as unresolved observations for a
registry owner to classify.

Release publication accepts an existing clean, pushed commit. It never stages or
creates the release commit. Publication occurs from a clean temporary checkout,
and a tag is created only after registry and checksum verification.
