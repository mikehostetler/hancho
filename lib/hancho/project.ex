defmodule Hancho.Project do
  @moduledoc """
  Repository paths used by one Hancho software factory.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              root: Zoi.string() |> Zoi.min(1),
              hancho_dir: Zoi.string() |> Zoi.min(1),
              config_path: Zoi.string() |> Zoi.min(1),
              database_path: Zoi.string() |> Zoi.min(1),
              logs_path: Zoi.string() |> Zoi.min(1),
              workflows_path: Zoi.string() |> Zoi.min(1),
              worktrees_path: Zoi.string() |> Zoi.min(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(String.t()) :: t()
  def new(root) do
    root = Path.expand(root)
    hancho_dir = Path.join(root, ".hancho")

    Zoi.parse!(@schema, %{
      root: root,
      hancho_dir: hancho_dir,
      config_path: Path.join(hancho_dir, "config.toml"),
      database_path: Path.join(hancho_dir, "hancho.sqlite3"),
      logs_path: Path.join(hancho_dir, "logs"),
      workflows_path: Path.join(hancho_dir, "workflows"),
      worktrees_path: Path.join(hancho_dir, "worktrees")
    })
  end

  @spec log_path(t(), String.t()) :: {:ok, String.t()} | {:error, :unsafe_path}
  def log_path(%__MODULE__{} = project, relative_path) do
    case Path.safe_relative(relative_path, project.logs_path) do
      {:ok, safe_path} -> {:ok, Path.join(project.logs_path, safe_path)}
      :error -> {:error, :unsafe_path}
    end
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
