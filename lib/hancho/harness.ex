defmodule Hancho.Harness do
  @moduledoc false

  @default_progress_interval_ms 30_000

  def ensure_started do
    with :ok <- Hancho.Command.Runtime.ensure_started(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      :ok
    end
  end

  def run(provider, prompt, options \\ []) do
    with :ok <- ensure_started() do
      Jido.Harness.run(provider, prompt, options)
    end
  end

  def run_with_progress(provider, prompt, options, callback) when is_function(callback, 1) do
    await_timeout = Keyword.get(options, :await_timeout, :infinity)
    interval = Keyword.get(options, :progress_interval_ms, @default_progress_interval_ms)

    run_options =
      Keyword.drop(options, [:await_timeout, :progress_interval_ms])

    with :ok <- ensure_started(),
         {:ok, run_id} <- Jido.Harness.Run.start(provider, prompt, run_options),
         :ok <- notify(callback, progress(run_id, provider, :started, 0, 0, nil)),
         {:ok, result} <- await(run_id, provider, await_timeout, interval, callback) do
      {:ok, result}
    end
  end

  defp await(run_id, provider, timeout, interval, callback) do
    started_at = System.monotonic_time(:millisecond)
    deadline = deadline(started_at, timeout)
    await_next(run_id, provider, started_at, deadline, interval, 0, nil, callback)
  end

  defp await_next(
         run_id,
         provider,
         started_at,
         deadline,
         interval,
         cursor,
         latest,
         callback
       ) do
    wait = wait_time(deadline, interval)

    case Jido.Harness.Run.await(run_id, wait) do
      {:ok, result} ->
        {next_cursor, latest} = replay(run_id, cursor, latest)

        with :ok <-
               notify(
                 callback,
                 progress(run_id, provider, :completed, elapsed(started_at), next_cursor, latest)
               ) do
          {:ok, result}
        end

      {:error, :timeout} ->
        if expired?(deadline) do
          {:error, :timeout}
        else
          {next_cursor, latest} = replay(run_id, cursor, latest)

          with :ok <-
                 notify(
                   callback,
                   progress(run_id, provider, :running, elapsed(started_at), next_cursor, latest)
                 ) do
            await_next(
              run_id,
              provider,
              started_at,
              deadline,
              interval,
              next_cursor,
              latest,
              callback
            )
          end
        end

      error ->
        error
    end
  end

  defp replay(run_id, cursor, latest) do
    case Jido.Harness.Run.replay(run_id, cursor: cursor, limit: 10_000) do
      {:ok, []} -> {cursor, latest}
      {:ok, events} -> {List.last(events).sequence, List.last(events)}
      {:error, _reason} -> {cursor, latest}
    end
  end

  defp progress(run_id, provider, phase, elapsed_ms, event_count, latest) do
    %{
      harness_run_id: run_id,
      provider: provider,
      phase: phase,
      elapsed_ms: elapsed_ms,
      event_count: event_count,
      last_event: if(latest, do: latest.type),
      last_sequence: if(latest, do: latest.sequence),
      provider_session_id: latest_provider_session_id(latest)
    }
  end

  defp latest_provider_session_id(nil), do: nil
  defp latest_provider_session_id(event), do: event.provider_session_id

  defp notify(callback, progress) do
    case callback.(progress) do
      :ok -> :ok
      {:error, reason} -> {:error, {:progress_callback_failed, reason}}
      other -> {:error, {:invalid_progress_callback_return, other}}
    end
  rescue
    error -> {:error, {:progress_callback_failed, {:exception, error}}}
  end

  defp deadline(_started_at, :infinity), do: :infinity
  defp deadline(started_at, timeout), do: started_at + timeout

  defp wait_time(:infinity, interval), do: interval
  defp wait_time(deadline, interval), do: min(max(deadline - now(), 0), interval)
  defp expired?(:infinity), do: false
  defp expired?(deadline), do: now() >= deadline
  defp elapsed(started_at), do: now() - started_at
  defp now, do: System.monotonic_time(:millisecond)
end
