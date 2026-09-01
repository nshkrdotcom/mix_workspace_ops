# Architecture

## Product boundary

MWO is an operator-side portfolio development/release control plane around
ordinary Mix projects. It owns portfolio-wide identity, local binding, views,
dependency intelligence, source policy, command scope, portable plans, runtime
arrangement, and release transactions. Mix remains authoritative for dependency
existence/requirements, dependency SCM behavior, compilation, incremental build
validity, and Mix task semantics. Hex owns normal package resolution/cache
behavior. Git owns repository semantics. Blitz owns bounded fan-out scheduling.

Managed repositories remain independently usable without MWO.

## Layers

```text
portable registry + views
        |
        v
identity / binding / ledger / drift
        |
        v
real Mix probes -> DependencyIndex -> Impact / Selection
        |                    |
        v                    v
source Resolution        plan scope
        |                    |
        +------> Overlay <---+
                    |
                    v
          Runtime + Blitz fan-out
                    |
              Mix / Git / Hex

release topology + descriptor
        |
        v
clean checkout -> actual prod deps -> gates -> publisher -> verify -> tag -> receipt
```

## Registry, views, and binding

MWO consumes only `portfolio_registry.registry/v2` and
`portfolio_registry.view/v2`. These artifacts are portable and contain no
operator paths or credentials.

Repository identity is verified from Git evidence. A matching directory name is
not sufficient. Operator-specific exact bindings and ignore observations live in
the operator ledger, separate from portable data. Duplicate canonical bindings
or contradictory exact binding evidence fail closed.

## Real Mix probing

`MixWorkspaceOps.Project` evaluates actual `mix.exs` in a disposable probe tree
with explicit Mix env/target. The tree contains incidental dependency/build/config
writes so the source checkout stays clean. It is not a security sandbox; project
code executes with the operator's OS authority.

One invocation can memoize probe results so dependency indexing, planning, and
related queries do not repeatedly evaluate the same project.

## DependencyIndex and Impact

`DependencyIndex` builds selected-scope dependency facts from project probe
results. Provider classification reuses the registry's canonical provider logic.
The source-policy table never substitutes for dependency truth.

The index has forward managed edges and reverse traversal data plus coverage.
Absent/unprobeable selected projects make coverage incomplete.

`Impact` resolves one target identity and traverses reverse managed edges to
produce direct/transitive consumers, repository aggregation, explanation paths,
and coverage. `Selection` converts that into execution scope. Incomplete coverage
forces affected execution back to the complete base selection.

## Source resolution

The committed `mix.exs` tuple defines standalone behavior. Registry
`dependency_sources` describes eligible local/Git/Hex source coordinates and
order. XDG `SourcePreferences` stores only an operator's preferred mode.
Command-local `--mode`/`--source` takes precedence for one invocation.

The local path is always derived from verified binding. Git and Hex coordinates
come only from the registry.

`Resolution.why/4`, plan construction, and actual execution use the same source
decision logic.

## Minimal bootstrap and lockfile seam

The managed repository integration is only the conditional bootstrap load and
dependency wrapper. The bootstrap parses a generated process-scoped overlay and
substitutes source options when active.

```elixir
if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defp deps do
  [
    workspace_dep({:example_core, "~> 1.0"})
  ]
end

defp workspace_dep(committed) do
  if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
    do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
    else: committed
end
```

MWO does not implement package materialization. Standard Mix/Hex resolves Hex
dependencies. Git mirrors are only transport rewrites; Mix still creates and owns
Git dependency checkouts.

The source checkout's `mix.lock` is never modified. `Lockfile` safely parses only
a literal top-level lock map, removes entries for dependencies actively replaced
by local paths when required by Mix, and computes audit digests. One operational
lock is retained with each dependency context; invocations work on private
copies, and explicitly allowed mutations are atomically promoted after a
compare-and-swap check. Malformed retained locks are quarantined and rebuilt.
`Lockfile` does not interpret or fetch package objects.

External lockfile redirection uses Mix's non-public post-config facility. That
dependency is isolated in the bootstrap's single `LockfileCompat` seam and fails
clearly if unsupported. Runtime and Git-mirror coordination deliberately use
Mix's non-public synchronization-lock implementation so MWO and Mix share the
same proven cross-process locking behavior. These two Mix compatibility surfaces
must be exercised on every supported Elixir/Mix version. MWO uses no private Hex
API.

## Plans and execution

Direct `run` is a current-state operation. `OperationPlan` v2 is the portable
frozen handoff/replay boundary. It binds registry/view identity, normalized scope,
command/policy, toolchain, units, source decisions, and dependency-index/impact
facts under one document digest. It contains no local paths or credentials.

Replay rebuilds current semantics and compares named dimensions. Material drift
is a refusal; a new operation requires a new plan.

`Fanout` binds portable units to local runtime state and delegates concurrency to
Blitz. Results retain deterministic logical-unit ordering even when jobs finish
out of order. A failed fan-out still emits the complete known report.

## Runtime contexts

Runtime state is operator-owned and external to managed repositories.

Different build contexts execute concurrently. Operations that share a build
context hold Mix's cross-process lock for the complete child command, not only
its compilation step. A concurrent compile therefore cannot replace artifacts
while another test or run still uses that context.

Dependency context identity includes only compatibility-relevant inputs such as
Mix env/target, toolchain, projected source-lock identity, and source-resolution identity.
It excludes absolute checkout roots and ordinary target source HEAD/dirt.

Build context identity is project-specific and includes the dependency context,
Mix env/target, and toolchain. It remains stable across normal source edits so
Mix incremental compilation can do its job.

Per-invocation HOME/config/working-lock/report state remains private. The
accepted operational lock is retained inside the matching dependency context so
`deps.get` and a later compile/test command form one normal managed workflow. `TMPDIR`
is operator-private but shared by managed operations because Mix derives its
cross-process lock namespace from the system temporary directory; separate
temporary roots would silently disable coordination for identical paths.
Credential-free download/archive caches and Git mirrors may be shared. Runtime
leases prevent GC from deleting live contexts.

## Diagnostics

`Doctor` reports binding/Git/probe health. Identity/probe contradictions are
errors; dirty/default-branch development state and ordinary absence can be
warnings/status rather than globally fatal.

`Drift` assigns explicit `error`, `warning`, or `info` severities. Exact binding
failure and ambiguous portfolio identity are errors. Unexplained scratch clones,
stale ignore observations, and ordinary discovery failures are visible warnings
where they do not establish an identity contradiction.

Release does not inherit these relaxed development semantics; it operates on a
clean exact pushed revision.

## Release

The release plan remains portable catalog policy. The operator descriptor supplies
concrete version/tag/gate/publisher policy. Each release unit is checked out at
its exact pushed revision before gates/publication.

At that clean-checkout boundary `Release.Preflight.verify_topology/5` probes
`MIX_ENV=prod`, maps actual managed dependencies to release packages, and verifies
the declared prerequisite closure. A missing managed publish prerequisite blocks
before gates/publisher. Non-Hex publish strategies and dependencies excluded by
prod Mix semantics do not create false Hex ordering requirements.

Credentials enter only the publisher capability. Exact publication state is
verified before tags are created/pushed. Durable ordered receipts make resume
idempotent and externally revalidated.
