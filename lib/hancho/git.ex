defmodule Hancho.Git do
  @moduledoc """
  Hancho's interface to the Git command-line client.

  All Git commands use erlexec so Hancho can stop the command and its process
  group when a timeout occurs.
  """

  @type option :: {:working_dir, String.t()} | {:timeout, pos_integer()}

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
  end

  @spec status([option()]) :: {:ok, Git.Status.t()} | {:error, term()}
  def status(options \\ []) do
    options
    |> config()
    |> then(&Git.status(config: &1))
  end
end
