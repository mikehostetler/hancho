defmodule Hancho.CLI.Commands.Logs do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.Factory.Client
  alias Hancho.{Error, ReadModel, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute(args, options) do
    filters = parse_filters(args, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, data} <- load_logs(repository, filters) do
      if Keyword.get(filters, :follow, false) do
        follow(repository, filters, data, options)
      else
        %Result{data: Map.put(data, :result, "ok"), text: format_logs(data)}
      end
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  defp parse_filters([], filters), do: filters

  defp parse_filters(["--run", run_id | rest], filters),
    do: parse_filters(rest, Keyword.put(filters, :run_id, run_id))

  defp parse_filters(["--station", station | rest], filters),
    do: parse_filters(rest, Keyword.put(filters, :station, station))

  defp parse_filters(["--since", since | rest], filters),
    do: parse_filters(rest, Keyword.put(filters, :since, since))

  defp parse_filters(["--raw" | rest], filters),
    do: parse_filters(rest, Keyword.put(filters, :raw, true))

  defp parse_filters(["--follow" | rest], filters),
    do: parse_filters(rest, Keyword.put(filters, :follow, true))

  defp parse_filters([run_id], filters), do: Keyword.put(filters, :run_id, run_id)

  defp parse_filters(_args, _filters) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho logs [--run RUN_ID] [--station ID] [--since 30m] [--raw] [--follow]"
  end

  defp load_logs(repository, filters) do
    if Keyword.get(filters, :raw, false) and Keyword.get(filters, :follow, false) do
      {:error,
       %Error{
         code: :raw_follow_not_supported,
         exit_status: 64,
         message: "Follow the normalized event stream. Use '--raw' without '--follow'."
       }}
    else
      load_log_view(repository, filters)
    end
  end

  defp load_log_view(repository, filters) do
    if Keyword.get(filters, :raw) do
      case Keyword.get(filters, :run_id) do
        nil ->
          {:error,
           %Error{
             code: :run_required,
             exit_status: 64,
             message: "Raw logs require '--run RUN_ID'."
           }}

        run_id ->
          with {:ok, logs} <- ReadModel.raw_logs(repository, run_id) do
            {:ok,
             %{
               raw_logs: logs,
               sensitive_warning: "Raw logs can contain source code or sensitive data."
             }}
          end
      end
    else
      with {:ok, events} <- ReadModel.filtered_logs(repository, filters),
           do: {:ok, %{events: events}}
    end
  end

  defp follow(repository, filters, %{events: events}, options) do
    emit_events(events, options)
    seen = MapSet.new(events, &event_key/1)
    {all_events, _seen} = follow_loop(repository, filters, events, seen, options)

    %Result{
      data: %{result: "stopped", events: all_events},
      text: "Log follow ended because the local factory stopped."
    }
  end

  defp follow_loop(repository, filters, events, seen, options) do
    Process.sleep(250)

    case ReadModel.filtered_logs(repository, filters) do
      {:ok, current} ->
        fresh = Enum.reject(current, &MapSet.member?(seen, event_key(&1)))
        emit_events(fresh, options)
        next_seen = Enum.reduce(fresh, seen, &MapSet.put(&2, event_key(&1)))
        all = events ++ fresh

        if Client.running?(repository) do
          follow_loop(repository, filters, all, next_seen, options)
        else
          {all, next_seen}
        end

      {:error, _failure} ->
        {events, seen}
    end
  end

  defp emit_events(events, options) do
    Enum.each(events, fn event ->
      if Keyword.get(options, :json, false) do
        IO.puts(Hancho.JSON.encode!(%{schema_version: 1, type: "event", event: event}))
      else
        IO.puts(format_event(event))
      end
    end)
  end

  defp event_key(event), do: {event["run_id"], event["seq"], event["event"]}

  defp format_logs(%{raw_logs: logs, sensitive_warning: warning}) do
    warning <>
      "\n" <>
      Enum.map_join(logs, "\n", &"#{&1["relative_path"]}\n#{&1["content"]}")
  end

  defp format_logs(%{events: events}) do
    Enum.map_join(events, "\n", &format_event/1)
  end

  defp format_event(event),
    do:
      "#{event["occurred_at"]} #{event["run_id"]} #{event["result_state"]} #{event["event"]} actor=#{event["actor"]}"
end
