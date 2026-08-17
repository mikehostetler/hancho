defmodule Hancho.Init do
  @moduledoc false

  @ignore_rule "/.hancho/"

  def run(options \\ []) do
    cwd = Keyword.get(options, :cwd, File.cwd!())
    project_api = Keyword.get(options, :project_api, Hancho.Project)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         :ok <- create_runtime(project),
         :ok <- ensure_gitignore(project.root) do
      {:ok, project.hancho_dir}
    else
      {:error, :git_not_found} -> {:error, "Git executable not found in PATH."}
      {:error, :not_git_repository} -> {:error, "Current directory is not in a Git repository."}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp create_runtime(project) do
    with :ok <- File.mkdir_p(project.logs_path),
         :ok <- File.mkdir_p(project.state_path),
         :ok <- File.chmod(project.hancho_dir, 0o700),
         :ok <- write_initial_config(project) do
      :ok
    end
  end

  defp write_initial_config(project) do
    if File.exists?(project.config_path) do
      :ok
    else
      with {:ok, config} <- Hancho.Config.default(project),
           {:ok, contents} <- Hancho.Config.encode(config) do
        File.write(project.config_path, contents)
      end
    end
  end

  defp ensure_gitignore(repository) do
    path = Path.join(repository, ".gitignore")
    contents = read_or_empty(path)

    if ignored?(contents) do
      :ok
    else
      File.write(path, append_line(contents, @ignore_rule))
    end
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp ignored?(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in [".hancho/", "/.hancho/"]))
  end

  defp append_line("", line), do: line <> "\n"

  defp append_line(contents, line) do
    String.trim_trailing(contents) <> "\n" <> line <> "\n"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
