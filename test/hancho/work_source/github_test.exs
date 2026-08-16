defmodule Hancho.WorkSource.GitHubTest do
  use Hancho.RepositoryCase, async: false

  @moduletag :integration

  alias Hancho.WorkSource.GitHub
  alias Hancho.{Config, Journal, Repository}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "gh-work")
    fixture_root = temporary_directory!("gh")
    log = Path.join(fixture_root, "calls.log")
    command = github_fixture!(fixture_root, log, :success)
    old = System.get_env("HANCHO_GH")
    System.put_env("HANCHO_GH", command)
    on_exit(fn -> restore_env("HANCHO_GH", old) end)
    %{repository: repository, run_id: work_order["id"], log: log, fixture_root: fixture_root}
  end

  test "reads accepted issue scope without writing", context do
    assert {:ok, issue} =
             GitHub.view_issue(context.repository, "https://github.com/example/project/issues/10")

    assert issue["number"] == 10
    refute File.read!(context.log) =~ "comment"
  end

  test "posts a material event once and rejects routine progress", context do
    assert {:ok, first} =
             GitHub.post_material_event(
               context.repository,
               context.run_id,
               "10",
               "blocker",
               "Blocked by a required owner decision."
             )

    assert first["status"] == "confirmed"

    assert {:ok, second} =
             GitHub.post_material_event(
               context.repository,
               context.run_id,
               "10",
               "blocker",
               "Blocked by a required owner decision."
             )

    assert second["id"] == first["id"]
    assert length(Regex.scan(~r/issue comment/, File.read!(context.log))) == 1

    assert {:error, %{code: :routine_github_event_rejected}} =
             GitHub.post_material_event(
               context.repository,
               context.run_id,
               "10",
               "harness_progress",
               "Half done"
             )
  end

  test "keeps workflow state unchanged when a GitHub write is uncertain", context do
    command = github_fixture!(context.fixture_root, context.log, :fail_comment)
    System.put_env("HANCHO_GH", command)

    assert {:ok, effect} =
             GitHub.link_beadwork(context.repository, context.run_id, "10", "bw-a123")

    assert effect["status"] == "uncertain"
    assert {:ok, work_order} = Journal.get_work_order(context.repository, context.run_id)
    assert work_order["state"] == "released"
  end

  defp github_fixture!(root, log, mode) do
    path = Path.join(root, "gh-#{mode}")

    fail_comment =
      if mode == :fail_comment, do: "[ \"$1 $2\" = \"issue comment\" ] && exit 8", else: ":"

    File.write!(
      path,
      """
      #!/bin/sh
      printf '%s\n' "$*" >> '#{log}'
      #{fail_comment}
      if [ "$1 $2" = "issue view" ]; then
        printf '{"number":10,"title":"Accepted work","state":"OPEN","url":"https://github.com/example/project/issues/10","body":"scope","labels":[]}\n'
      elif [ "$1 $2" = "issue comment" ]; then
        printf 'https://github.com/example/project/issues/10#issuecomment-1\n'
      else
        exit 64
      fi
      """
    )

    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
