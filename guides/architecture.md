# Architecture

Mix evaluates dependencies while loading `mix.exs`, before an external Mix task
can inject a workspace-wide source policy. Mix Workspace Ops addresses that
bootstrap limitation with a small, versioned project bootstrap and an explicit
operator-generated data overlay.

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

The same activation allocates content-addressed operator state for dependencies,
builds, Hex data, and an overlay-specific lockfile. Its key includes registry
and graph digests, source mode, target/dependency commits, the canonical lock
digest, and the Elixir/OTP toolchain. Managed repositories retain their tracked
lock and cannot share mutable build state across source modes or Unix operators.

Registry discovery is an evidence-producing operation, not an authority by
itself. It only admits independent canonical Git roots for an explicitly named
owner. Real Mix metadata supplies application identity. Duplicate applications
and projects that cannot load are emitted as unresolved observations for a
registry owner to classify.

Release publication accepts an existing clean, pushed commit. It never stages or
creates the release commit. Publication occurs from a clean temporary checkout,
and a tag is created only after registry and checksum verification.
