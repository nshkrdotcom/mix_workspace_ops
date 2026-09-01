# Contract examples

## Managed repository seam

A managed repository remains an ordinary Mix project. Only a dependency whose
source is switchable needs the conditional bootstrap + wrapper seam:

```elixir
if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP") do
  Code.require_file(bootstrap)
end

defp workspace_dep(committed) do
  if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
    do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
    else: committed
end
```

With no MWO environment the committed tuple is unchanged.

## Delegated runner

`delegated_runner.exs` demonstrates the environment inheritance contract for a
cache-aware child runner:

- MWO supplies an opaque semantic context digest;
- the delegated runner owns its child execution cache/receipts;
- normal process inheritance carries the MWO bootstrap and source overlay to
  child Mix commands;
- the runner does not read the portfolio registry or parse the source overlay.

The integration suite creates disposable repositories around the example rather
than embedding a production client repository.

## Impact consumer

`mix_workspace_ops impact TARGET` is the supported machine-readable surface for
an external CI/agent scheduler that wants portfolio dependency facts. External
systems may consume that report; MWO does not become their general job scheduler.
