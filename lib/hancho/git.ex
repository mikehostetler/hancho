defmodule Hancho.Git do
  @moduledoc """
  Hancho's interface to the Git command-line client.

  All Git commands use erlexec so Hancho can stop the command and its process
  group when a timeout occurs.
  """

  @type option ::
          {:binary, String.t()} | {:working_dir, String.t()} | {:timeout, pos_integer()}

  @spec executable() :: {:ok, String.t()} | {:error, :not_found}
  def executable do
    case System.find_executable("git") do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @spec config([option()]) :: Git.Config.t()
  def config(options \\ []) do
    options
    |> Keyword.put(:runner, Hancho.Git.Runner)
    |> Git.Config.new()
  end

  @spec repository_root([option()]) :: {:ok, String.t()} | {:error, term()}
  def repository_root(options \\ []) do
    options
    |> config()
    |> then(&Git.Info.root(config: &1))
  rescue
    error -> {:error, {:exception, error}}
  end

  @spec status([option()]) :: {:ok, Git.Status.t()} | {:error, term()}
  def status(options \\ []) do
    options
    |> config()
    |> then(&Git.status(config: &1))
  rescue
    error -> {:error, {:exception, error}}
  end
end
