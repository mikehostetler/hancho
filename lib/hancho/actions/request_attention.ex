defmodule Hancho.Actions.RequestAttention do
  @moduledoc "Creates a durable human decision or question and waits for its resolution."

  use Jido.Action,
    name: "hancho_request_attention",
    description: "Stops a workflow at a durable human attention gate",
    schema:
      Zoi.object(%{
        kind: Zoi.enum(["approval", "clarification", "scope_exception", "recovery"]),
        title: Zoi.string() |> Zoi.min(1),
        body: Zoi.string() |> Zoi.min(1)
      })

  @impl true
  def run(params, context) do
    with %{api: api, store: store, run_id: run_id} <- Map.get(context, :effect_store),
         id = run_id <> ":attention:" <> context.step,
         {:ok, record} <-
           api.request_attention(store, %{
             id: id,
             run_id: run_id,
             step: context.step,
             role: Map.get(context, :role),
             kind: params.kind,
             title: params.title,
             body: params.body
           }) do
      result(record)
    else
      nil -> {:error, :attention_store_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp result(%{"status" => "approved"} = record), do: {:ok, response(record)}
  defp result(%{"status" => "answered"} = record), do: {:ok, response(record)}

  defp result(%{"status" => "rejected"} = record),
    do: {:error, {:attention_rejected, response(record)}}

  defp result(record) do
    {:error,
     %{
       code: "attention_required",
       attention_id: record["id"],
       kind: record["kind"],
       title: record["title"]
     }}
  end

  defp response(record),
    do: %{attention_id: record["id"], status: record["status"], response: record["response"]}
end
