defmodule Hancho.Actions.CloseIssue do
  @moduledoc "Records the commit, closes the issue, and syncs Beadwork."

  use Jido.Action,
    name: "hancho_close_issue",
    description: "Closes and syncs one Beadwork issue",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        issue_id: Zoi.string() |> Zoi.min(1),
        commit: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context

  @impl true
  def run(params, context) do
    beadwork = Context.service(context, :beadwork, Hancho.Beadwork)
    options = [working_dir: params.repo_path]

    with {:ok, _comment} <-
           beadwork.comment(params.issue_id, "Implemented in #{params.commit}.", options),
         {:ok, _closed} <- beadwork.close(params.issue_id, options),
         {:ok, _output} <- beadwork.sync(options) do
      {:ok, %{issue_id: params.issue_id, commit: params.commit, status: "closed"}}
    end
  end
end
