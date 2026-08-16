defmodule Hancho.CLI.Commands.Status do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Factory.{Client, Store}
  alias Hancho.{Error, Journal, JSON, ReadModel, Repository}

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, status} <- status(repository) do
      %Result{data: Map.put(status, "result", "ok"), text: format(status)}
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error, code: :invalid_arguments, exit_status: 64, message: "Usage: hancho status"
  end

  defp status(repository) do
    case Client.request(repository, "status", %{}, 500) do
      {:ok, status} -> {:ok, status}
      {:error, _error} -> stopped_status(repository)
    end
  end

  defp stopped_status(repository) do
    metadata = read_metadata(repository)

    with {:ok, queue} <- Store.list(repository),
         {:ok, decisions} <- Journal.open_decisions(repository),
         {:ok, effects} <- Journal.uncertain_effects(repository),
         {:ok, actions} <- Journal.uncertain_actions(repository),
         {:ok, andon} <- ReadModel.andon_stops(repository) do
      {:ok,
       Map.merge(metadata, %{
         "state" => "stopped",
         "health" => "stopped",
         "ready_work" => Enum.filter(queue, &(&1["status"] == "ready")),
         "active_work" => Enum.filter(queue, &(&1["status"] == "active")),
         "blocks" => Enum.filter(queue, &(&1["status"] in ["stopped", "failed"])),
         "decisions" => decisions,
         "uncertain_effects" => effects,
         "uncertain_actions" => actions,
         "andon" => andon,
         "next_command" => "hancho up"
       })}
    end
  end

  defp read_metadata(repository) do
    with {:ok, content} <- File.read(Client.metadata_path(repository)),
         metadata when is_map(metadata) <- JSON.decode!(content) do
      metadata
    else
      _ -> %{"host" => nil, "factory_id" => nil}
    end
  rescue
    _ -> %{"host" => nil, "factory_id" => nil}
  end

  defp format(status) do
    wip = status["wip"] || %{"active" => length(status["active_work"] || []), "limit" => "-"}

    "Factory #{status["state"]} health=#{status["health"]} host=#{status["host"] || "-"} " <>
      "wip=#{wip["active"]}/#{wip["limit"]} ready=#{length(status["ready_work"] || [])} " <>
      "blocks=#{length(status["blocks"] || [])} next=#{status["next_command"]}"
  end
end
