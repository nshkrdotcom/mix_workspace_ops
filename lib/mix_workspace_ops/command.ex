defmodule MixWorkspaceOps.Command do
  @moduledoc "Structured external-command execution without a shell."

  @enforce_keys [:executable, :args, :cwd, :exit_code, :output]
  defstruct [:executable, :args, :cwd, :exit_code, :output]

  @type t :: %__MODULE__{
          executable: String.t(),
          args: [String.t()],
          cwd: String.t(),
          exit_code: non_neg_integer(),
          output: String.t()
        }

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, t()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cwd = opts |> Keyword.get(:cd, File.cwd!()) |> Path.expand()
    env = Keyword.get(opts, :env, [])

    {output, exit_code} = execute(executable, args, cwd, env)

    result = %__MODULE__{
      executable: executable,
      args: args,
      cwd: cwd,
      exit_code: exit_code,
      output: output
    }

    if exit_code == 0, do: {:ok, result}, else: {:error, result}
  end

  defp execute(executable, args, cwd, env) do
    System.cmd(executable, args,
      cd: cwd,
      env: env,
      stderr_to_stdout: true
    )
  rescue
    error in [ErlangError, ArgumentError] -> {Exception.message(error), 127}
  end

  @spec run!(String.t(), [String.t()], keyword()) :: t()
  def run!(executable, args, opts \\ []) do
    case run(executable, args, opts) do
      {:ok, result} ->
        result

      {:error, result} ->
        raise MixWorkspaceOps.CommandError, result: result
    end
  end
end

defmodule MixWorkspaceOps.CommandError do
  @moduledoc false

  defexception [:message, :result]

  @impl Exception
  def exception(opts) do
    result = Keyword.fetch!(opts, :result)

    message =
      "command failed with exit #{result.exit_code}: " <>
        Enum.join([result.executable | result.args], " ") <> "\n" <> result.output

    %__MODULE__{message: message, result: result}
  end
end
