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
  alias Hancho.Workflow.Effect

  @impl true
  def run(params, context) do
    beadwork = Context.service(context, :beadwork, Hancho.Beadwork)
    options = [working_dir: params.repo_path]

    run_id = context[:run_id] || "run"
    comment = "Implemented in #{params.commit}. [hancho:#{run_id}:close]"

    with {:ok, _receipt} <- comment(beadwork, params, options, comment, context),
         {:ok, _receipt} <- close(beadwork, params, options, context),
         {:ok, _receipt} <- sync(beadwork, params, options, context) do
      {:ok, %{issue_id: params.issue_id, commit: params.commit, status: "closed"}}
    end
  end

  defp comment(beadwork, params, options, text, context) do
    Effect.run(
      context,
      "comment",
      "beadwork.comment",
      %{issue_id: params.issue_id, text: text},
      fn -> reconcile_comment(beadwork, params.issue_id, text, options) end,
      fn ->
        with {:ok, _comment} <- beadwork.comment(params.issue_id, text, options) do
          {:ok, %{issue_id: params.issue_id, text: text}}
        end
      end
    )
  end

  defp close(beadwork, params, options, context) do
    Effect.run(
      context,
      "close",
      "beadwork.close",
      %{issue_id: params.issue_id, commit: params.commit},
      fn -> reconcile_close(beadwork, params.issue_id, options) end,
      fn ->
        with {:ok, _closed} <- beadwork.close(params.issue_id, options) do
          {:ok, %{issue_id: params.issue_id, status: "closed"}}
        end
      end
    )
  end

  defp sync(beadwork, params, options, context) do
    Effect.run(
      context,
      "sync",
      "beadwork.sync",
      %{issue_id: params.issue_id},
      fn -> :not_applied end,
      fn ->
        with {:ok, _output} <- beadwork.sync(options) do
          {:ok, %{issue_id: params.issue_id, synced: true}}
        end
      end
    )
  end

  defp reconcile_comment(beadwork, issue_id, text, options) do
    case beadwork.show(issue_id, options) do
      {:ok, %{"status" => "closed"}} ->
        {:ok, %{issue_id: issue_id, text: text}}

      {:ok, issue} ->
        if contains_text?(issue, text),
          do: {:ok, %{issue_id: issue_id, text: text}},
          else: :not_applied

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_close(beadwork, issue_id, options) do
    case beadwork.show(issue_id, options) do
      {:ok, %{"status" => "closed"}} -> {:ok, %{issue_id: issue_id, status: "closed"}}
      {:ok, _issue} -> :not_applied
      {:error, reason} -> {:error, reason}
    end
  end

  defp contains_text?(value, text) when is_binary(value), do: String.contains?(value, text)

  defp contains_text?(value, text) when is_list(value),
    do: Enum.any?(value, &contains_text?(&1, text))

  defp contains_text?(value, text) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&contains_text?(&1, text))

  defp contains_text?(_value, _text), do: false
end
