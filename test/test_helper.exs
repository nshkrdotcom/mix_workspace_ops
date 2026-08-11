ExUnit.start()
Code.require_file("support/workspace_case_helper.exs", __DIR__)

Code.require_file(
  Path.join(:code.priv_dir(:mix_workspace_ops), "bootstrap/mix_workspace_ops_bootstrap.exs")
)
