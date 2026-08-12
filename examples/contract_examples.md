# Contract examples

These examples model extension seams without integrating a real ecosystem
repository.

`delegated_runner.exs` is the complete contract for a cache-aware
multi-project runner:

- MWO supplies `MIX_WORKSPACE_OPS_CONTEXT_DIGEST` as an opaque cache input;
- the runner owns its child dependency, build, and Hex state;
- ordinary process inheritance carries the MWO bootstrap and source overlay to
  child Mix commands;
- the runner neither reads EER nor parses an overlay.

The integration suite creates disposable standalone, umbrella, poncho, and
delegated-runner repositories around this example. No named client repository
is embedded in the fixture.
