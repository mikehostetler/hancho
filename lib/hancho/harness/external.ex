defmodule Hancho.Harness.External do
  @moduledoc false
  @behaviour Hancho.Harness.Adapter

  alias Hancho.Harness.{ProcessRunner, Protocol, Request}
  alias Hancho.{Error, JSON}

  @impl true
  def doctor(config), do: operation(config, "doctor")

  @impl true
  def version(config), do: operation(config, "version")

  @impl true
  def run(%Request{} = request, config) do
    request_path = request.paths["request"]
    File.mkdir_p!(Path.dirname(request_path))
    File.write!(request_path, Protocol.encode_request(request))

    with {:ok, adapter} <- adapter_path(config),
         {:ok, process} <-
           ProcessRunner.run(adapter, ["run", request_path],
             cwd: request.repository_path,
             stdout_path: request.paths["stdout"],
             stderr_path: request.paths["stderr"],
             timeout_ms: request.limits["timeout_ms"] || 900_000,
             max_output_bytes: request.limits["max_output_bytes"] || 10_485_760,
             cancel_ref: config["cancel_ref"]
           ) do
      case process.status do
        "success" ->
          output = File.read!(process.stdout_path)

          Protocol.parse_output(output, %{
            adapter: adapter,
            harness: config["command"],
            adapter_version: config["adapter_version"],
            harness_version: config["harness_version"],
            stdout_path: process.stdout_path,
            stderr_path: process.stderr_path
          })

        status ->
          {:error,
           %Error{
             code: String.to_atom("adapter_#{status}"),
             exit_status: 75,
             message:
               "External adapter ended with '#{status}'. Raw output: #{process.stdout_path}."
           }}
      end
    end
  end

  defp operation(config, operation) do
    with {:ok, adapter} <- adapter_path(config) do
      case System.cmd(adapter, [operation],
             cd: config["repository_path"] || File.cwd!(),
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          data = if String.trim(output) == "", do: %{}, else: JSON.decode!(output)
          {:ok, data}

        {output, status} ->
          {:error,
           %Error{
             code: :adapter_check_failed,
             exit_status: 69,
             message: "Adapter #{operation} failed with #{status}: #{String.trim(output)}"
           }}
      end
    end
  rescue
    error ->
      {:error,
       %Error{code: :adapter_check_failed, exit_status: 69, message: Exception.message(error)}}
  end

  defp adapter_path(config) do
    adapter = config["adapter"]
    root = config["repository_path"] || File.cwd!()

    if Path.type(adapter) == :absolute do
      {:ok, adapter}
    else
      resolved = Path.expand(adapter, root)
      boundary = Path.expand(Path.join(root, ".hancho/harnesses")) <> "/"

      if String.starts_with?(resolved, boundary) do
        {:ok, resolved}
      else
        {:error,
         %Error{
           code: :adapter_path_escape,
           exit_status: 78,
           message:
             "Relative adapter '#{adapter}' must stay under the repository .hancho/harnesses folder."
         }}
      end
    end
  end
end
