defmodule Hancho.Repository do
  @moduledoc "Discovers and initializes one repository-local factory unit."

  alias Hancho.{Error, ID, JSON, Store}

  @runtime_directories ["runs", "harnesses", "locks", "tmp"]

  defstruct [:id, :root, :git_common_dir, :branch, :remote, :runtime_dir]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          root: String.t(),
          git_common_dir: String.t(),
          branch: String.t() | nil,
          remote: String.t() | nil,
          runtime_dir: String.t()
        }

  @spec discover(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def discover(path \\ File.cwd!()) do
    expanded = Path.expand(path)

    with {:ok, root} <- git(expanded, ["rev-parse", "--show-toplevel"]),
         {:ok, common} <- git(root, ["rev-parse", "--git-common-dir"]) do
      root = Path.expand(root)

      common =
        if Path.type(common) == :absolute,
          do: Path.expand(common),
          else: Path.expand(common, root)

      runtime_dir = Path.join(root, ".hancho")

      {:ok,
       %__MODULE__{
         id: read_repository_id(runtime_dir),
         root: root,
         git_common_dir: common,
         branch: optional_git(expanded, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         remote: optional_git(expanded, ["config", "--get", "remote.origin.url"]),
         runtime_dir: runtime_dir
       }}
    else
      {:error, _error} ->
        {:error,
         %Error{
           code: :not_a_git_repository,
           exit_status: 66,
           message: "No Git repository contains '#{expanded}'. No files changed."
         }}
    end
  end

  @spec init(t()) :: {:ok, map()} | {:error, Error.t()}
  def init(%__MODULE__{} = repository) do
    with :ok <- create_runtime(repository),
         {:ok, config_status} <- write_initial_config(repository),
         {:ok, ignore_status} <- ensure_gitignore(repository.root),
         {:ok, repository} <- ensure_identity(repository),
         :ok <- Store.migrate(Store.path(repository)) do
      File.chmod(Store.path(repository), 0o600)

      {:ok,
       %{
         result: "initialized",
         repository_id: repository.id,
         repository_root: repository.root,
         runtime_dir: repository.runtime_dir,
         config: config_status,
         gitignore: ignore_status
       }}
    end
  end

  @spec config_path(t()) :: Path.t()
  def config_path(repository), do: Path.join(repository.runtime_dir, "config.toml")

  defp create_runtime(repository) do
    File.mkdir_p!(repository.runtime_dir)
    File.chmod(repository.runtime_dir, 0o700)

    Enum.each(@runtime_directories, fn directory ->
      path = Path.join(repository.runtime_dir, directory)
      File.mkdir_p!(path)
      File.chmod(path, 0o700)
    end)

    :ok
  rescue
    error in File.Error ->
      {:error,
       %Error{
         code: :runtime_init_failed,
         exit_status: 73,
         message: "Cannot create '#{repository.runtime_dir}': #{Exception.message(error)}"
       }}
  end

  defp write_initial_config(repository) do
    path = config_path(repository)

    if File.exists?(path) do
      {:ok, "preserved"}
    else
      case File.write(path, Hancho.Config.default_toml(), [:exclusive]) do
        :ok ->
          File.chmod(path, 0o600)
          {:ok, "created"}

        {:error, :eexist} ->
          {:ok, "preserved"}

        {:error, reason} ->
          {:error,
           %Error{
             code: :config_write_failed,
             exit_status: 73,
             message: "Cannot write '#{path}': #{:file.format_error(reason)}"
           }}
      end
    end
  end

  defp ensure_gitignore(root) do
    path = Path.join(root, ".gitignore")
    content = if File.exists?(path), do: File.read!(path), else: ""

    effective? =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 in [".hancho/", "/.hancho/"]))

    if effective? do
      {:ok, "preserved"}
    else
      separator = if content == "" or String.ends_with?(content, "\n"), do: "", else: "\n"

      File.write!(
        path,
        content <> separator <> "# Hancho local configuration and runtime data\n.hancho/\n"
      )

      {:ok, "updated"}
    end
  rescue
    error in File.Error ->
      {:error,
       %Error{
         code: :gitignore_write_failed,
         exit_status: 73,
         message: "Cannot update '#{Path.join(root, ".gitignore")}': #{Exception.message(error)}"
       }}
  end

  defp ensure_identity(repository) do
    path = Path.join(repository.runtime_dir, "repository.json")

    repository = %{repository | id: repository.id || ID.generate("repo")}

    data = %{
      schema_version: 1,
      repository_id: repository.id,
      control_checkout: repository.root,
      git_common_directory: repository.git_common_dir,
      remote: repository.remote
    }

    if File.exists?(path) do
      {:ok, repository}
    else
      File.write!(path, JSON.encode!(data), [:exclusive])
      File.chmod(path, 0o600)
      {:ok, repository}
    end
  rescue
    error in File.Error ->
      {:error,
       %Error{
         code: :identity_write_failed,
         exit_status: 73,
         message: "Cannot write repository identity: #{Exception.message(error)}"
       }}
  end

  defp read_repository_id(runtime_dir) do
    path = Path.join(runtime_dir, "repository.json")

    with true <- File.exists?(path),
         {:ok, data} <- File.read(path),
         %{"repository_id" => id} when is_binary(id) <- JSON.decode!(data) do
      id
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  end

  defp optional_git(path, args) do
    case git(path, args) do
      {:ok, ""} -> nil
      {:ok, output} -> output
      {:error, _} -> nil
    end
  end
end
