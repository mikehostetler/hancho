defmodule Hancho.Harness.Fake do
  @moduledoc false
  @behaviour Hancho.Harness.Adapter

  alias Hancho.Harness.{Request, Result}
  alias Hancho.{Error, ID}

  @impl true
  def doctor(_config),
    do: {:ok, %{status: "pass", adapter: "fake", detail: "Deterministic in-process test adapter"}}

  @impl true
  def version(_config), do: {:ok, %{adapter_version: "1", harness_version: "fake-1"}}

  @impl true
  def run(%Request{} = request, config) do
    mode = Map.get(config, "mode", "success")
    delay = Map.get(config, "delay_ms", 0)
    notify_observer(config, request)
    if delay > 0, do: Process.sleep(delay)

    case mode do
      "raise" ->
        raise "fake adapter failure"

      "malformed" ->
        {:error,
         %Error{
           code: :malformed_adapter_output,
           exit_status: 76,
           message: "The fake adapter emitted malformed output."
         }}

      "slow_output" ->
        write_slow_output(request, Map.get(config, "chunk_delay_ms", 10))
        result(request, "success")

      status when status in ["success", "failure", "timeout", "cancelled", "output_limit"] ->
        result(request, status)
    end
  end

  defp result(request, status) do
    {:ok,
     %Result{
       status: status,
       adapter: "builtin:fake",
       harness: "fake",
       adapter_version: "1",
       harness_version: "fake-1",
       session_id: ID.generate("session"),
       exit_status: if(status == "success", do: 0, else: 1),
       stdout_path: request.paths["stdout"],
       stderr_path: request.paths["stderr"],
       events: [%{"type" => "event", "name" => "fake.completed", "status" => status}]
     }}
  end

  defp write_slow_output(request, delay) do
    stdout = request.paths["stdout"]
    stderr = request.paths["stderr"]
    File.mkdir_p!(Path.dirname(stdout))
    File.write!(stdout, "first chunk\n")
    File.write!(stderr, "slow warning\n")
    Process.sleep(delay)
    File.write!(stdout, "second chunk\n", [:append])
  end

  defp notify_observer(config, request) do
    case Map.get(config, "observer") || Map.get(config, :observer) do
      observer when is_pid(observer) -> send(observer, {:fake_request, request})
      _ -> :ok
    end
  end
end
