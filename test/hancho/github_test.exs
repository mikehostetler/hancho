defmodule Hancho.GitHubTest do
  use ExUnit.Case, async: true

  alias Hancho.Command.Result

  defmodule Command do
    def run("/test/gh", ["repo", "view", "--json", "nameWithOwner"], _options) do
      {:ok, %Result{stdout: ~s({"nameWithOwner":"owner/repo"}), stderr: "", exit_status: 0}}
    end

    def run("/test/gh", ["api", "graphql" | arguments], options) do
      send(self(), {:graphql, arguments, options})

      output =
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "issues" => %{
                "pageInfo" => %{"hasNextPage" => false},
                "nodes" => [
                  %{
                    "id" => "node-1",
                    "number" => 1,
                    "title" => "Demand",
                    "url" => "https://github.test/owner/repo/issues/1",
                    "state" => "OPEN",
                    "body" => "Acceptance",
                    "parent" => nil,
                    "subIssues" => %{"totalCount" => 0},
                    "comments" => %{
                      "pageInfo" => %{"hasNextPage" => false},
                      "nodes" => [%{"body" => "Hancho-Beadwork-Epic: bw-1"}]
                    }
                  }
                ]
              }
            }
          }
        })

      {:ok, %Result{stdout: output, stderr: "", exit_status: 0}}
    end

    def run("/test/gh", ["api", "repos/owner/repo/issues/1/comments", "-f", body], _options) do
      send(self(), {:comment, body})
      {:ok, %Result{stdout: ~s({"id":123}), stderr: "", exit_status: 0}}
    end
  end

  test "reads stable repository and Issue identities through the command boundary" do
    assert {:ok, %{repository: "owner/repo", issues: [issue]}} =
             Hancho.GitHub.list_open(
               executable: "/test/gh",
               command: Command,
               working_dir: "/repo"
             )

    assert issue.node_id == "node-1"
    assert issue.number == 1
    assert issue.comments == ["Hancho-Beadwork-Epic: bw-1"]
    assert_received {:graphql, arguments, [cwd: "/repo", stderr_to_stdout: true]}
    assert "owner=owner" in arguments
    assert "name=repo" in arguments

    assert {:ok, %{"id" => 123}} =
             Hancho.GitHub.comment(issue, "Hancho-Beadwork-Epic: bw-1",
               executable: "/test/gh",
               command: Command
             )

    assert_received {:comment, "body=Hancho-Beadwork-Epic: bw-1"}
  end
end
