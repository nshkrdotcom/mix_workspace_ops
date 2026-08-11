# Architecture

Mix evaluates dependencies while loading `mix.exs`, before an external Mix task
can inject a workspace-wide source policy. Mix Workspace Ops addresses that
bootstrap limitation with a small, versioned project bootstrap and an explicit
operator-generated data overlay.

Version requirements remain in each package's `mix.exs`. The workspace catalog
contains repository and project coordinates only. With no overlay, a package is
an ordinary standalone Hex consumer. With an explicit local overlay, managed
dependencies resolve to validated sibling paths.

The operator tool is separate from:

- Blitz, which executes and fingerprints workspace commands;
- Weld, which projects and verifies publishable poncho artifacts;
- StackLab, which proves product and platform behavior.

Release publication accepts an existing clean, pushed commit. It never stages or
creates the release commit. Publication occurs from a clean temporary checkout,
and a tag is created only after registry and checksum verification.
