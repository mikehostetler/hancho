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
  alias Hancho.Workflow.Effect

  @impl true
  def run(%{repo_path: repository, issue: issue}, context) do
    beadwork = Context.service(context, :beadwork, Hancho.Beadwork)

    issue_id = issue["id"] || issue[:id]

    Effect.run(
      context,
      "claim",
      "beadwork.start",
      %{repository: repository, issue_id: issue_id},
      fn -> reconcile(beadwork, issue_id, repository) end,
      fn -> start(beadwork, issue, repository) end
    )
  end

  defp reconcile(beadwork, issue_id, repository) do
    case beadwork.show(issue_id, working_dir: repository) do
      {:ok, %{"status" => "in_progress"} = issue} -> {:ok, %{issue: issue}}
      {:ok, %{"status" => "open"}} -> :not_applied
      {:ok, _issue} -> {:error, "The Beadwork task cannot be claimed."}
      {:error, reason} -> {:error, reason}
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
