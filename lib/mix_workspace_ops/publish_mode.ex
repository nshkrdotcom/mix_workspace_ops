defmodule MixWorkspaceOps.PublishMode do
  @moduledoc """
  Whether the command about to run publishes, read from the tasks it names.

  Publishing is detected from the command, never requested by an operator and
  never carried in an environment variable, because a published package that
  quietly kept a local path or a git ref is the failure this exists to prevent.

  Detection reads task position only. `mix do compile, hex.publish` publishes;
  `mix run --arg hex.publish` does not, and a membership test over raw argv
  cannot tell them apart. The parser splits `,` and `+` separators, skips the
  `do` keyword, and takes the token after each separator as a task and every
  token after that as its arguments.

  `hex.info` and `hex.outdated` are deliberately absent from the publish tasks.
  They read the registry and must resolve exactly the way ordinary development
  does.

  The quiet tasks are the ones whose standard output is consumed by other
  tooling. They never receive the local-path notice, so nothing reading `mix`
  output gets an extra line injected into it.
  """

  @publish_tasks ~w(hex.publish hex.build deps.publish_preflight)
  @quiet_tasks ~w(run eval cmd app.start app.config escript.build deps.sources
                  deps.publish_preflight)

  @doc "The tasks that publish."
  @spec publish_tasks() :: [String.t()]
  def publish_tasks, do: @publish_tasks

  @doc "The tasks whose output is the product, and which carry no notice."
  @spec quiet_tasks() :: [String.t()]
  def quiet_tasks, do: @quiet_tasks

  @doc "True when `argv` names a publishing task in task position."
  @spec publish?([String.t()]) :: boolean()
  def publish?(argv) when is_list(argv) do
    argv |> task_tokens() |> Enum.any?(&(&1 in @publish_tasks))
  end

  @doc "True when `argv` names a task whose output must carry no notice."
  @spec quiet?([String.t()]) :: boolean()
  def quiet?(argv) when is_list(argv) do
    argv |> task_tokens() |> Enum.any?(&(&1 in @quiet_tasks))
  end

  @doc """
  Every token in task position, in order.

  Mix strips its own name before a task reads `System.argv/0`, so the first
  token is a task.
  """
  @spec task_tokens([String.t()]) :: [String.t()]
  def task_tokens(argv) when is_list(argv) do
    argv
    |> Enum.flat_map(&split_separators/1)
    |> collect([], true)
    |> Enum.reverse()
  end

  @doc """
  The task tokens of a command Mix Workspace Ops is about to launch.

  The command carries its executable, which Mix would have stripped. A command
  that does not run `mix` runs no Mix task, so it names none.
  """
  @spec task_argv([String.t()]) :: [String.t()]
  def task_argv([executable | argv]) do
    if Path.basename(executable) == "mix", do: argv, else: []
  end

  def task_argv([]), do: []

  defp split_separators(argument) do
    case String.split(argument, ",") do
      [single] -> [single]
      parts -> parts |> Enum.intersperse(",") |> Enum.reject(&(&1 == ""))
    end
  end

  defp collect([], acc, _task?), do: acc

  defp collect([token | rest], acc, _task?) when token in [",", "+"],
    do: collect(rest, acc, true)

  defp collect(["do" | rest], acc, true), do: collect(rest, acc, true)
  defp collect(["" | rest], acc, true), do: collect(rest, acc, true)
  defp collect([token | rest], acc, true), do: collect(rest, [token | acc], false)
  defp collect([_token | rest], acc, false), do: collect(rest, acc, false)
end
