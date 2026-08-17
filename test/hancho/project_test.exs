defmodule Hancho.ProjectTest do
  use ExUnit.Case, async: true

  defmodule Git do
    def executable, do: {:ok, "/usr/bin/git"}
    def repository_root(working_dir: path), do: {:ok, Path.join(path, "repo")}
  end

  defmodule MissingGit do
    def executable, do: {:error, :not_found}
  end

  defmodule NoRepository do
    def executable, do: {:ok, "/usr/bin/git"}
    def repository_root(_options), do: {:error, {"not a repository", 128}}
  end

  test "discovers all repository-local Hancho paths" do
    assert {:ok, project} = Hancho.Project.discover(cwd: "/work", git: Git)
    assert project.root == "/work/repo"
    assert project.hancho_dir == "/work/repo/.hancho"
    assert project.config_path == "/work/repo/.hancho/config.toml"
    assert project.logs_path == "/work/repo/.hancho/logs"
    assert project.bedrock_path == "/work/repo/.hancho/bedrock"
    assert project.forensics_path == "/work/repo/.hancho/forensics"
    assert project.workflows_path == "/work/repo/.hancho/workflows"
    assert project.worktrees_path == "/work/repo/.hancho/worktrees"

    assert Hancho.Project.log_path(project, "runs/factory.jsonl") ==
             {:ok, "/work/repo/.hancho/logs/runs/factory.jsonl"}
  end

  test "rejects a log path outside the repository log directory" do
    project = Hancho.Project.new("/repo")

    assert Hancho.Project.log_path(project, "../state/data") == {:error, :unsafe_path}
    assert Hancho.Project.log_path(project, "/tmp/factory.log") == {:error, :unsafe_path}
  end

  test "reports missing Git and a missing repository" do
    assert Hancho.Project.discover(git: MissingGit) == {:error, :git_not_found}
    assert Hancho.Project.discover(git: NoRepository) == {:error, :not_git_repository}
  end
end
