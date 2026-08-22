defmodule Hancho.DemandsTest do
  use ExUnit.Case, async: true

  alias Hancho.GitHub.Issue

  defmodule ReadGitHub do
    def list_open(_options) do
      send(self(), :github_read)
      {:ok, %{repository: "owner/repo", issues: Process.get(:github_issues, [])}}
    end

    def comment(issue, body, _options) do
      send(self(), {:github_comment, issue.url, body})

      issues =
        Enum.map(Process.get(:github_issues, []), fn current ->
          if current.node_id == issue.node_id,
            do: %{current | comments: current.comments ++ [body]},
            else: current
        end)

      Process.put(:github_issues, issues)
      {:ok, %{"id" => 1}}
    end
  end

  defmodule ReadBeadwork do
    def list_all(_options) do
      send(self(), :beadwork_read)
      {:ok, Process.get(:beadwork_issues, [])}
    end

    def create(title, type, description, parent, _options) do
      id = if type == "epic", do: "bw-epic", else: "bw-task"

      issue = %{
        "id" => id,
        "title" => title,
        "type" => type,
        "status" => "open",
        "parent" => parent,
        "blocked_by" => [],
        "description" => description,
        "comments" => []
      }

      send(self(), {:beadwork_create, id, parent})
      Process.put(:beadwork_issues, Process.get(:beadwork_issues, []) ++ [issue])
      {:ok, issue}
    end

    def comment(id, body, _options) do
      send(self(), {:beadwork_comment, id, body})
      {:ok, %{"id" => id}}
    end
  end

  defmodule Lease do
    def with_lease(_project, _options, function), do: function.()
  end

  defmodule Cache do
    def intent(_project, repository, actions) do
      send(self(), {:cache_intent, repository, actions})
      :ok
    end

    def receipt(_project, repository, records, actions) do
      send(self(), {:cache_receipt, repository, length(records), actions})
      :ok
    end
  end

  setup do
    Process.put(:github_issues, [])
    Process.put(:beadwork_issues, [])
    project = Hancho.Project.new("/repo")

    %{
      project: project,
      options: [github: ReadGitHub, beadwork: ReadBeadwork, lease_api: Lease, cache: Cache]
    }
  end

  test "shows mapped demands and an open orphan without writing", %{
    project: project,
    options: options
  } do
    root = github_issue("root", 10, nil, ["Hancho-Beadwork-Epic: bw-epic"])
    child = github_issue("child", 11, "root", ["Hancho-Beadwork-Task: bw-task"])
    Process.put(:github_issues, [root, child])

    Process.put(:beadwork_issues, [
      beadwork("bw-epic", "epic", nil, root),
      beadwork("bw-task", "task", "bw-epic", child),
      %{"id" => "orphan", "title" => "Local work", "type" => "task", "status" => "open"}
    ])

    assert {:ok, result} = Hancho.Demands.list(project, "all", options)
    assert Enum.map(result.records, & &1.mapping_status) == ["mapped", "mapped", "unmapped"]
    assert_receive :github_read
    assert_receive :beadwork_read
    refute_received {:github_comment, _, _}
    refute_received {:beadwork_create, _, _}
    refute_received {:cache_intent, _, _}
  end

  test "dry-run plans creation but does not mutate either system", %{
    project: project,
    options: options
  } do
    Process.put(:github_issues, [github_issue("root", 10, nil, [])])

    assert {:ok, %{mode: :dry_run, actions: [action]}} =
             Hancho.Demands.sync(project, :dry_run, options)

    assert action =~ "create Beadwork epic"
    assert Process.get(:beadwork_issues) == []
    refute_received {:github_comment, _, _}
    refute_received {:cache_intent, _, _}
  end

  test "apply creates parented records and backlinks, then proves the mapping", %{
    project: project,
    options: options
  } do
    root = github_issue("root", 10, nil, [])
    child = github_issue("child", 11, "root", [])
    Process.put(:github_issues, [root, child])

    assert {:ok, %{mode: :apply, records: records}} =
             Hancho.Demands.sync(project, :apply, options)

    assert Enum.all?(records, &(&1.mapping_status == "mapped"))
    assert_received {:beadwork_create, "bw-epic", nil}
    assert_received {:beadwork_create, "bw-task", "bw-epic"}
    assert_received {:github_comment, _, "Hancho-Beadwork-Epic: bw-epic"}
    assert_received {:github_comment, _, "Hancho-Beadwork-Task: bw-task"}
    assert_received {:cache_intent, "owner/repo", _}
    assert_received {:cache_receipt, "owner/repo", 2, _}
  end

  test "duplicate mappings stop synchronization", %{project: project, options: options} do
    root = github_issue("root", 10, nil, [])
    Process.put(:github_issues, [root])

    Process.put(:beadwork_issues, [
      beadwork("one", "epic", nil, root),
      beadwork("two", "epic", nil, root)
    ])

    assert {:error, {:demand_mapping_conflicts, findings}} =
             Hancho.Demands.sync(project, :apply, options)

    assert Enum.any?(findings, &(&1.code == "duplicate"))
    refute_received {:beadwork_create, _, _}
  end

  test "a nested sub-issue is an audit error and cannot synchronize", %{
    project: project,
    options: options
  } do
    root = github_issue("root", 10, nil, [])
    child = %{github_issue("child", 11, "root", []) | child_count: 1}
    Process.put(:github_issues, [root, child])

    assert {:ok, %{findings: findings}} = Hancho.Demands.audit(project, options)
    assert Enum.any?(findings, &(&1.code == "nested_sub_issue" and &1.severity == "error"))

    assert {:error, {:demand_mapping_conflicts, _findings}} =
             Hancho.Demands.sync(project, :apply, options)
  end

  test "a GitHub backlink to an unknown Beadwork ID stops creation", %{
    project: project,
    options: options
  } do
    root = github_issue("root", 10, nil, ["Hancho-Beadwork-Epic: missing-id"])
    Process.put(:github_issues, [root])

    assert {:error, {:demand_mapping_conflicts, findings}} =
             Hancho.Demands.sync(project, :apply, options)

    assert Enum.any?(findings, &String.contains?(&1.message, "unknown Beadwork record"))
    refute_received {:beadwork_create, _, _}
  end

  defp github_issue(node, number, parent, comments) do
    {:ok, issue} =
      Issue.new(%{
        repository: "owner/repo",
        node_id: node,
        number: number,
        title: "Issue #{number}",
        url: "https://github.test/owner/repo/issues/#{number}",
        state: "open",
        parent_node_id: parent,
        comments: comments,
        child_count: if(parent, do: 0, else: 1)
      })

    issue
  end

  defp beadwork(id, type, parent, github) do
    %{
      "id" => id,
      "title" => github.title,
      "type" => type,
      "status" => "open",
      "parent" => parent,
      "blocked_by" => [],
      "description" =>
        "Hancho-GitHub-#{if(type == "epic", do: "Issue", else: "Sub-Issue")}: #{github.url}\nHancho-GitHub-Node: #{github.node_id}",
      "comments" => []
    }
  end
end
