defmodule Hancho.Project do
  @moduledoc """
  Repository paths used by one Hancho software factory.
  """

  @enforce_keys [:root, :hancho_dir, :config_path, :logs_path, :state_path]
  defstruct [:root, :hancho_dir, :config_path, :logs_path, :state_path]

  @type t :: %__MODULE__{
          root: String.t(),
          hancho_dir: String.t(),
          config_path: String.t(),
          logs_path: String.t(),
          state_path: String.t()
        }

  @spec new(String.t()) :: t()
  def new(root) do
    root = Path.expand(root)
    hancho_dir = Path.join(root, ".hancho")

    %__MODULE__{
      root: root,
      hancho_dir: hancho_dir,
      config_path: Path.join(hancho_dir, "config.toml"),
      logs_path: Path.join(hancho_dir, "logs"),
      state_path: Path.join(hancho_dir, "state")
    }
  end

  @spec discover(keyword()) :: {:ok, t()} | {:error, :git_not_found | :not_git_repository}
  def discover(options \\ []) do
    cwd = Keyword.get(options, :cwd, File.cwd!())
    git = Keyword.get(options, :git, Hancho.Git)

    with {:ok, _executable} <- git.executable(),
         {:ok, root} <- git.repository_root(working_dir: cwd) do
      {:ok, new(root)}
    else
      {:error, :not_found} -> {:error, :git_not_found}
      {:error, _reason} -> {:error, :not_git_repository}
    end
  end
end
