defmodule Hancho.Init do
  @moduledoc false

  @config "version = 1\n"
  @ignore_rule "/.hancho/"

  def run(options \\ []) do
    cwd = Keyword.get(options, :cwd, File.cwd!())
    find_executable = Keyword.get(options, :find_executable, &System.find_executable/1)
    command = Keyword.get(options, :command, &System.cmd/3)

    with {:ok, git} <- find_git(find_executable),
         {:ok, repository} <- repository_root(command, git, cwd),
         {:ok, path} <- create_runtime(repository),
         :ok <- ensure_gitignore(repository) do
      {:ok, path}
    end
  end

  defp find_git(find_executable) do
    case find_executable.("git") do
      nil -> {:error, "Git executable not found in PATH."}
      path -> {:ok, path}
    end
  end

  defp repository_root(command, git, cwd) do
    case command.(git, ["rev-parse", "--show-toplevel"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, "Current directory is not in a Git repository."}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp create_runtime(repository) do
    path = Path.join(repository, ".hancho")

    with :ok <- File.mkdir_p(Path.join(path, "logs")),
         :ok <- File.mkdir_p(Path.join(path, "state")),
         :ok <- File.chmod(path, 0o700),
         :ok <- write_initial_config(Path.join(path, "config.toml")) do
      {:ok, path}
    end
  end

  defp write_initial_config(path) do
    if File.exists?(path), do: :ok, else: File.write(path, @config)
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
end
