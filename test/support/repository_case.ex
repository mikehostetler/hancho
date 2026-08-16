defmodule Hancho.RepositoryCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Hancho.RepositoryCase
    end
  end

  def temporary_directory!(name \\ "factory") do
    path =
      Path.join(temporary_root(), "hancho-test-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  def temporary_git_repository!(name \\ "factory") do
    path = temporary_directory!(name)
    {_output, 0} = System.cmd("git", ["init", "-q", path], stderr_to_stdout: true)

    File.write!(
      Path.join(path, ".git/config"),
      "\n[user]\n\tname = Hancho Test\n\temail = hancho@example.test\n",
      [:append]
    )

    File.write!(Path.join(path, "README.md"), "# Fixture\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", "README.md"])
    {_output, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "Initial fixture"])
    path
  end

  defp temporary_root do
    key = {__MODULE__, :temporary_root}

    case :persistent_term.get(key, nil) do
      nil ->
        {root, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
        root = String.trim(root)
        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end
end
