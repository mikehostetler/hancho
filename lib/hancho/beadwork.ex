defmodule Hancho.Beadwork do
  @moduledoc """
  Hancho's interface to the Beadwork command-line client.
  """

  alias Hancho.Command.Result

  @spec executable() :: {:ok, String.t()} | {:error, :not_found}
  def executable do
    case System.find_executable("bw") do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @spec version(keyword()) :: {:ok, String.t()} | {:error, term()}
  def version(options \\ []), do: run(["--version"], options)

  @spec repository_config(keyword()) :: {:ok, String.t()} | {:error, term()}
  def repository_config(options \\ []), do: run(["config", "list"], options)

  defp run(arguments, options) do
    command = Keyword.get(options, :command, Hancho.Command)
    cwd = Keyword.get(options, :working_dir, File.cwd!())

    with {:ok, executable} <- executable(),
         {:ok, %Result{stdout: output, exit_status: 0}} <-
           command.run(executable, arguments, cwd: cwd, stderr_to_stdout: true) do
      {:ok, String.trim(output)}
    else
      {:ok, %Result{stdout: output, exit_status: status}} ->
        {:error, {String.trim(output), status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
