defmodule Hancho.Git.Runner do
  @moduledoc false

  @behaviour Git.Runner

  alias Hancho.Command.Result

  @impl true
  def run(binary, arguments, options) do
    options =
      options
      |> Keyword.delete(:stderr_to_stdout)
      |> Keyword.put(:stderr_to_stdout, true)
      |> rename_option(:cd, :cwd)

    case Hancho.Command.run(binary, arguments, options) do
      {:ok, %Result{stdout: stdout, exit_status: exit_status}} ->
        {:ok, {stdout, exit_status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rename_option(options, old, new) do
    case Keyword.pop(options, old) do
      {nil, options} -> options
      {value, options} -> Keyword.put(options, new, value)
    end
  end
end
