defmodule Hancho.RepositoryCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Hancho.RepositoryCase
    end
  end

  def temporary_directory!(name \\ "factory") do
    path =
      Path.join(System.tmp_dir!(), "hancho-test-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    {path, 0} = System.cmd("pwd", ["-P"], cd: path)
    path = String.trim(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  def temporary_git_repository!(name \\ "factory") do
    path = temporary_directory!(name)
    {_output, 0} = System.cmd("git", ["init", "-q", path], stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Hancho Test"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.email", "hancho@example.test"])
    File.write!(Path.join(path, "README.md"), "# Fixture\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", "README.md"])
    {_output, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "Initial fixture"])
    path
  end
end
