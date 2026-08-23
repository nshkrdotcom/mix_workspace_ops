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

Version requirements remain in each package's `mix.exs`. A caller-supplied
registry contains stable repository and project coordinates only. Dependency
edges are derived from current Mix metadata; they are never copied into the
registry. With no overlay, a package is an ordinary standalone Hex consumer.
With an explicit local overlay, managed dependencies resolve to validated
sibling paths.

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
registry targets. Application uniqueness applies only to projects that declare
an OTP application; no fake app name is introduced for a tooling or umbrella
root.

Registry discovery is an evidence-producing operation, not an authority by
itself. It only admits independent canonical Git roots for an explicitly named
owner. Real Mix metadata supplies application identity. Duplicate applications
and projects that cannot load are emitted as unresolved observations for a
registry owner to classify.

Release publication accepts an existing clean, pushed commit. It never stages or
creates the release commit. Publication occurs from a clean temporary checkout,
and a tag is created only after registry and checksum verification.
