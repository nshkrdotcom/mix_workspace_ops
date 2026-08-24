defmodule MixWorkspaceOps.PublishMode do
  @moduledoc """
  Whether the command about to run publishes, read from the tasks it names.

  Publishing is detected from the command and never requested by an operator or
  carried in an environment variable, so that resolving for publication is a
  consequence of publishing rather than of remembering to ask.

  ## What reading a task name can and cannot do

  This is a **user-error check, not a security boundary**, and it cannot be one:
  a name is not a capability. Someone who means to publish under a development
  overlay can run the publisher directly, and nothing here would see it. What
  makes a development overlay unusable for publication is the seam's own refusal
  at the point the overlay is read, which does not depend on recognising a task
  name; and what keeps credentials away from ordinary work is that they are
  supplied only to the release transaction's publishing step.

  Detection reads task position only. `mix do compile, hex.publish` publishes;
  `mix run --arg hex.publish` does not, and a membership test over raw argv
  cannot tell them apart. Outside `mix do`, only the first token is a task.
  Inside it, a standalone `,` or `+`, or a comma at the end of the preceding
  token, introduces the next task. Commas embedded in arguments remain data.

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
  token is a task. Only `mix do` introduces further task positions.
  """
  @spec task_tokens([String.t()]) :: [String.t()]
  def task_tokens(["do" | argv]), do: argv |> collect_do([], true) |> Enum.reverse()
  def task_tokens([task | _arguments]) when task != "", do: [task]
  def task_tokens(argv) when is_list(argv), do: []

  @doc """
  The task tokens of a command Mix Workspace Ops is about to launch.

  The command carries its executable, which Mix would have stripped. Three
  shapes reach the same `mix`: `mix …`, `elixir -S mix …`, and either of those
  behind `env` with or without leading assignments. A command that reaches no
  `mix` runs no Mix task, so it names none.
  """
  @spec task_argv([String.t()]) :: [String.t()]
  def task_argv([executable | argv]) do
    case Path.basename(executable) do
      "mix" -> argv
      "elixir" -> scripted_task_argv(argv)
      "env" -> argv |> Enum.drop_while(&String.contains?(&1, "=")) |> task_argv()
      _other -> []
    end
  end

  def task_argv([]), do: []

  # `elixir -S mix` asks the launcher to find `mix` on PATH and run it, so the
  # tokens after it are exactly what `mix` itself would have received.
  defp scripted_task_argv(argv) do
    case Enum.drop_while(argv, &(&1 != "-S")) do
      ["-S", script | rest] -> if Path.basename(script) == "mix", do: rest, else: []
      _unscripted -> []
    end
  end

  defp collect_do([], acc, _task?), do: acc

  defp collect_do([token | rest], acc, _task?) when token in [",", "+"],
    do: collect_do(rest, acc, true)

  defp collect_do(["" | rest], acc, true), do: collect_do(rest, acc, true)

  defp collect_do([token | rest], acc, true) do
    if String.ends_with?(token, ",") do
      task = String.trim_trailing(token, ",")
      collect_do(rest, if(task == "", do: acc, else: [task | acc]), true)
    else
      collect_do(rest, [token | acc], false)
    end
  end

  defp collect_do([token | rest], acc, false) do
    collect_do(rest, acc, String.ends_with?(token, ","))
  end
end
