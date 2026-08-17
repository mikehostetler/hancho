defmodule Hancho.Actions.Verify do
  @moduledoc "Runs verification and retains compact and complete output records."

  @progress_bytes 65_536

  use Jido.Action,
    name: "hancho_verify",
    description: "Runs a verification command in the worktree",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
        worktree_path: Zoi.string() |> Zoi.min(1),
        executable: Zoi.string() |> Zoi.min(1),
        arguments: Zoi.array(Zoi.string()),
        timeout_ms: Zoi.integer() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Command.Result

  @impl true
  def run(params, context) do
    command = Context.service(context, :command, Hancho.Command)
    executable = System.find_executable(params.executable) || params.executable

    with {:ok, output_path} <- prepare_output(params, context),
         {:ok, device} <- File.open(output_path, [:write, :binary, :exclusive]),
         :ok <- File.chmod(output_path, 0o600),
         {:ok, tracker} <-
           Agent.start_link(fn -> %{bytes: 0, chunks: 0, next_emit: @progress_bytes} end) do
      try do
        sink = output_sink(context.log, device, output_path, tracker)

        result =
          command.run(executable, params.arguments,
            cwd: params.worktree_path,
            timeout: params.timeout_ms,
            stderr_to_stdout: true,
            on_output: sink
          )

        stats = Agent.get(tracker, & &1)
        finish(result, output_path, stats, context.log)
      after
        if Process.alive?(tracker), do: Agent.stop(tracker)
        File.close(device)
      end
    end
  end

  defp prepare_output(params, context) do
    repository = params.repo_path || repository_from_worktree(params.worktree_path)
    logs_path = Path.join([repository, ".hancho", "logs"])
    run_id = safe_run_id(context[:run_id])
    unique = System.unique_integer([:positive, :monotonic])
    path = Path.join(logs_path, "#{run_id}-verify-#{unique}.log")

    with :ok <- File.mkdir_p(logs_path),
         :ok <- File.chmod(logs_path, 0o700) do
      {:ok, path}
    end
  end

  defp repository_from_worktree(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.find_index(parts, &(&1 == ".hancho")) do
      nil -> Path.expand(path)
      index -> parts |> Enum.take(index) |> Path.join()
    end
  end

  defp safe_run_id(nil), do: "run"

  defp safe_run_id(run_id) do
    String.replace(run_id, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp output_sink(log, device, output_path, tracker) do
    fn stream, output ->
      with :ok <- IO.binwrite(device, output),
           progress <- track(tracker, byte_size(output)),
           :ok <- maybe_log_progress(log, output_path, stream, progress) do
        :ok
      end
    end
  end

  defp track(tracker, size) do
    Agent.get_and_update(tracker, fn state ->
      updated = %{state | bytes: state.bytes + size, chunks: state.chunks + 1}

      if updated.bytes >= updated.next_emit do
        next_emit = (div(updated.bytes, @progress_bytes) + 1) * @progress_bytes
        {updated, %{updated | next_emit: next_emit}}
      else
        {nil, updated}
      end
    end)
  end

  defp maybe_log_progress(_log, _output_path, _stream, nil), do: :ok

  defp maybe_log_progress(log, output_path, stream, progress) do
    Hancho.Log.write(log, "Verification produced #{progress.bytes} bytes",
      event: "verify.progress",
      metadata: %{
        bytes: progress.bytes,
        chunks: progress.chunks,
        output_path: output_path,
        stream: stream
      }
    )
  end

  defp finish({:ok, %Result{} = result}, output_path, stats, log) do
    summary = summary(result.stdout)
    level = if result.exit_status == 0, do: :info, else: :error

    with :ok <-
           Hancho.Log.write(log, verification_message(result.exit_status, summary),
             event: "verify.completed",
             level: level,
             metadata: %{
               exit_status: result.exit_status,
               summary: summary,
               bytes: stats.bytes,
               chunks: stats.chunks,
               output_path: output_path
             }
           ) do
      if result.exit_status == 0 do
        {:ok,
         %{
           exit_status: 0,
           output: tail(result.stdout, 20_000),
           output_path: output_path,
           bytes: stats.bytes,
           chunks: stats.chunks,
           summary: summary
         }}
      else
        {:error,
         "Verification failed with exit status #{result.exit_status}. Full output: #{output_path}\n#{tail(result.stdout, 20_000)}"}
      end
    end
  end

  defp finish({:error, reason}, output_path, stats, log) do
    with :ok <-
           Hancho.Log.write(log, "Verification command stopped",
             event: "verify.stopped",
             level: :error,
             metadata: %{
               error: reason,
               bytes: stats.bytes,
               chunks: stats.chunks,
               output_path: output_path
             }
           ) do
      {:error, reason}
    end
  end

  defp verification_message(0, nil), do: "Verification completed"
  defp verification_message(0, summary), do: "Verification completed: #{summary}"
  defp verification_message(status, nil), do: "Verification failed with exit status #{status}"

  defp verification_message(status, summary),
    do: "Verification failed with exit status #{status}: #{summary}"

  defp summary(output) do
    value =
      case Regex.scan(~r/^Result:\s*.+$/m, output) |> List.last() do
        [result] -> result
        nil -> output |> String.split("\n", trim: true) |> List.last()
      end

    if value, do: String.slice(value, 0, 500)
  end

  defp tail(text, limit) when byte_size(text) <= limit, do: text
  defp tail(text, limit), do: binary_part(text, byte_size(text) - limit, limit)
end
