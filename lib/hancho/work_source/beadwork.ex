defmodule Hancho.WorkSource.Beadwork do
  @moduledoc "Beadwork execution-ledger operations through the `bw` CLI."

  alias Hancho.{Error, Journal, JSON, Repository}

  @spec ready(Repository.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def ready(repository, options \\ []) do
    with {:ok, data} <- read_json(repository, ["ready", "--json"]) do
      items = if is_list(data), do: data, else: [data]
      {:ok, select(items, options)}
    end
  end

  @spec list_all(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_all(repository) do
    with {:ok, data} <- read_json(repository, ["list", "--all", "--json"]) do
      {:ok, if(is_list(data), do: data, else: [data])}
    end
  end

  @spec select([map()], keyword()) :: [map()]
  def select(items, options) do
    only = Keyword.get(options, :only)
    max = Keyword.get(options, :max, 0)

    items =
      items
      |> Enum.sort_by(&{ordinal(&1), &1["id"]})
      |> apply_range(Keyword.get(options, :start_at), Keyword.get(options, :end_at))

    items
    |> Enum.filter(fn item -> is_nil(only) or item["id"] == only end)
    |> Enum.reject(fn item ->
      item["status"] == "closed" and not Keyword.get(options, :include_closed, false)
    end)
    |> Enum.reject(fn item ->
      item["blocked"] == true and not Keyword.get(options, :include_blocked, false)
    end)
    |> then(fn selected -> if max > 0, do: Enum.take(selected, max), else: selected end)
  end

  @spec selection_view([map()], keyword()) :: map()
  def selection_view(items, options \\ []) do
    selected = select(items, options)
    selected_ids = MapSet.new(selected, & &1["id"])

    explanations =
      items
      |> Enum.sort_by(&{ordinal(&1), &1["id"]})
      |> Enum.map(fn item ->
        reason =
          cond do
            MapSet.member?(selected_ids, item["id"]) -> "selected"
            item["status"] == "closed" -> "closed"
            item["blocked"] == true -> "open blocker"
            Keyword.get(options, :only) -> "not selected by --only"
            true -> "outside range or maximum"
          end

        %{id: item["id"], selected: reason == "selected", reason: reason}
      end)

    %{
      dry_run: Keyword.get(options, :dry_run, false),
      selected: selected,
      explanations: explanations
    }
  end

  @spec show(Repository.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def show(repository, id), do: read_json(repository, ["show", id, "--json"])

  @spec claim(Repository.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def claim(repository, run_id, id) do
    effect(repository, run_id, "beadwork_claim", id, "bw-claim:#{id}", ["start", id, "--json"])
  end

  @spec close(Repository.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def close(repository, run_id, id, reason) do
    with {:ok, effect} <-
           effect(
             repository,
             run_id,
             "beadwork_close",
             id,
             "bw-close:#{id}",
             ["close", id, "--reason", reason, "--json"]
           ) do
      case command(repository, ["sync"]) do
        {:ok, _} -> {:ok, Map.put(effect, "sync", "confirmed")}
        {:error, error} -> {:ok, Map.put(effect, "sync", "failed: #{error.message}")}
      end
    end
  end

  @spec link_github(Repository.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def link_github(repository, run_id, id, issue_url) do
    effect(
      repository,
      run_id,
      "beadwork_link",
      id,
      "bw-link:#{id}:#{issue_url}",
      ["comment", id, "Hancho-GitHub-Issue: #{issue_url}", "--json"]
    )
  end

  @spec create_discovered(Repository.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_discovered(repository, run_id, parent_id, discovery) do
    title = discovery["title"] || discovery[:title]

    description =
      "Discovered by Hancho run #{run_id}. Evidence: #{JSON.encode!(discovery["evidence"] || %{})}"

    effect(
      repository,
      run_id,
      "beadwork_create_discovered",
      parent_id,
      "bw-discovery:#{run_id}:#{title}",
      ["create", title, "--parent", parent_id, "--description", description, "--json"]
    )
  end

  defp effect(repository, run_id, kind, target, idempotency_key, args) do
    with {:ok, effect} <- Journal.effect_intent(repository, run_id, kind, target, idempotency_key),
         {:ok, effect} <- Journal.prepare_effect_retry(repository, effect) do
      case effect["status"] do
        "confirmed" ->
          {:ok, effect}

        "intent" ->
          case command(repository, args) do
            {:ok, output} ->
              observation = decode_or_text(output)

              Journal.observe_effect(repository, effect["id"], "confirmed", %{result: observation})

            {:error, error} ->
              Journal.observe_effect(repository, effect["id"], "uncertain", %{
                error: error.message
              })
          end

        status ->
          {:error,
           %Error{
             code: :effect_not_retryable,
             exit_status: 75,
             message: "Beadwork effect '#{effect["id"]}' is '#{status}' and needs reconciliation."
           }}
      end
    end
  end

  defp read_json(repository, args) do
    with {:ok, output} <- command(repository, args) do
      try do
        {:ok, JSON.decode!(output)}
      rescue
        _ ->
          {:error,
           %Error{
             code: :beadwork_invalid_json,
             exit_status: 65,
             message: "Beadwork returned invalid JSON."
           }}
      end
    end
  end

  defp command(repository, args) do
    command = System.get_env("HANCHO_BW") || "bw"

    case System.cmd(command, ["-C", repository.root | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error,
         %Error{
           code: :beadwork_failed,
           exit_status: 69,
           message: "Beadwork command failed with status #{status}: #{String.trim(output)}"
         }}
    end
  rescue
    error ->
      {:error,
       %Error{code: :beadwork_unavailable, exit_status: 69, message: Exception.message(error)}}
  end

  defp decode_or_text(""), do: %{}

  defp decode_or_text(output) do
    JSON.decode!(output)
  rescue
    _ -> %{text: output}
  end

  defp ordinal(item) do
    item["ordinal"] || get_in(item, ["metadata", "ordinal"]) || 999_999
  end

  defp apply_range(items, nil, nil), do: items

  defp apply_range(items, start_at, end_at) do
    start_index = if start_at, do: Enum.find_index(items, &(&1["id"] == start_at)), else: 0

    end_index =
      if end_at, do: Enum.find_index(items, &(&1["id"] == end_at)), else: length(items) - 1

    if is_integer(start_index) and is_integer(end_index) and start_index <= end_index do
      Enum.slice(items, start_index..end_index)
    else
      []
    end
  end
end
