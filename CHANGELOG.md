# Changelog

## Unreleased

- Establish the non-Hex operator escript, portable registry protocol, local source
  overlays, dependency planning, and fail-closed release transaction.
- Keep ordinary repositories zero-integration by materializing the Mix bootstrap
  in operator state instead of installing copied helper code.
- Separate machine-local overlay integrity from a path-independent semantic
  source-context digest and support explicit managed/delegated Mix-state owners.
- Accept non-application workspace roots and discover real example projects.
- Validate a portable prepared-artifact handoff without depending on the
  projection tool that produced it.
- Restrict `HEX_API_KEY` inheritance to the credential-bearing publish
  transition instead of accepting it in release descriptors.
