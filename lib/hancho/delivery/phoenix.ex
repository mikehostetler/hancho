defmodule Hancho.Delivery.Phoenix do
  @moduledoc false
  @behaviour Hancho.Delivery.Adapter

  alias Hancho.Delivery.{Request, Result}
  alias Hancho.Harness.ProcessRunner
  alias Hancho.{Artifacts, Error}

  @impl true
  def dry_run(%Request{} = request, _context) do
    command = request.options["command"]

    if is_binary(command) and executable(command) do
      {:ok,
       %Result{
         status: "contained",
         message: "Phoenix delivery plan is valid. No application was deployed.",
         evidence: %{command: command, arguments: request.options["arguments"] || []}
       }}
    else
      {:error,
       error(
         :phoenix_delivery_command_missing,
         "Phoenix delivery needs an executable command in adapter options."
       )}
    end
  end

  @impl true
  def execute(%Request{} = request, context) do
    run_dir = Artifacts.run_directory(context.repository, request.run_id)

    with {:ok, process} <-
           ProcessRunner.run(request.options["command"], request.options["arguments"] || [],
             cwd: context.repository.root,
             stdout_path: Path.join(run_dir, "logs/delivery-phoenix.stdout.log"),
             stderr_path: Path.join(run_dir, "logs/delivery-phoenix.stderr.log"),
             timeout_ms: context.timeout_ms,
             max_output_bytes: context.max_output_bytes
           ) do
      status = if process.status == "success", do: "confirmed", else: "uncertain"

      {:ok,
       %Result{
         status: status,
         message: "Phoenix deployment ended with #{process.status}.",
         evidence: process
       }}
    end
  end

  defp executable(command),
    do:
      (Path.type(command) == :absolute and File.exists?(command)) or
        not is_nil(System.find_executable(command))

  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
