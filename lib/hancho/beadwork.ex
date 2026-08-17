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

  @spec show(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def show(issue_id, options \\ []), do: run_json(["show", issue_id, "--json"], options)

  @spec ready(keyword()) :: {:ok, [map()]} | {:error, term()}
  def ready(options \\ []) do
    case run_json(["ready", "--json"], options) do
      {:ok, nil} -> {:ok, []}
      {:ok, issues} when is_list(issues) -> {:ok, issues}
      {:ok, value} -> {:error, {:invalid_ready_result, value}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_all(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all(options \\ []) do
    case run_json(["list", "--all", "--json"], options) do
      {:ok, nil} -> {:ok, []}
      {:ok, issues} when is_list(issues) -> {:ok, issues}
      {:ok, value} -> {:error, {:invalid_list_result, value}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(issue_id, options \\ []), do: run_json(["start", issue_id, "--json"], options)

  @spec comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def comment(issue_id, text, options \\ []),
    do: run_json(["comment", issue_id, text, "--json"], options)

  @spec close(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(issue_id, options \\ []), do: run_json(["close", issue_id, "--json"], options)

  @spec sync(keyword()) :: {:ok, String.t()} | {:error, term()}
  def sync(options \\ []), do: run(["sync"], options)

  defp run_json(arguments, options) do
    with {:ok, output} <- run(arguments, options),
         {:ok, values} <- Jason.decode(output) do
      {:ok, values}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run(arguments, options) do
    command = Keyword.get(options, :command, Hancho.Command)
    cwd = Keyword.get(options, :working_dir, File.cwd!())

    with {:ok, executable} <- resolve_executable(options),
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

  defp resolve_executable(options) do
    case Keyword.fetch(options, :executable) do
      {:ok, executable} -> {:ok, executable}
      :error -> executable()
    end
  end
end
