defmodule Hancho.Actions.ClaimIssue do
  @moduledoc "Claims one Beadwork issue for the workflow."

  use Jido.Action,
    name: "hancho_claim_issue",
    description: "Starts one Beadwork issue",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        issue: Zoi.map()
      })

  alias Hancho.Actions.Context

  @impl true
  def run(%{repo_path: repository, issue: issue}, context) do
    beadwork = Context.service(context, :beadwork, Hancho.Beadwork)

    case issue["status"] || issue[:status] do
      "in_progress" -> {:ok, %{issue: issue}}
      :in_progress -> {:ok, %{issue: issue}}
      "open" -> start(beadwork, issue, repository)
      :open -> start(beadwork, issue, repository)
      _status -> {:error, "The Beadwork task cannot be claimed."}
    end
  end

  defp start(beadwork, issue, repository) do
    issue_id = issue["id"] || issue[:id]

    case beadwork.start(issue_id, working_dir: repository) do
      {:ok, claimed} -> {:ok, %{issue: claimed}}
      {:error, reason} -> {:error, reason}
    end
  end
end
