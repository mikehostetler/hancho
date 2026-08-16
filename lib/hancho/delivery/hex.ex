defmodule Hancho.Delivery.Hex do
  @moduledoc false
  @behaviour Hancho.Delivery.Adapter

  alias Hancho.Delivery.{Request, Result}
  alias Hancho.Harness.ProcessRunner
  alias Hancho.{Artifacts, Error}

  @impl true
  def dry_run(%Request{} = request, context) do
    cond do
      not File.exists?(Path.join(context.repository.root, "mix.exs")) ->
        {:error, error(:hex_mix_project_missing, "Hex delivery needs mix.exs.")}

      is_nil(System.find_executable("mix")) ->
        {:error, error(:mix_unavailable, "The mix executable was not found.")}

      request.artifact == "" ->
        {:error, error(:delivery_artifact_missing, "Delivery artifact is empty.")}

      true ->
        {:ok,
         %Result{
           status: "contained",
           message: "Hex delivery plan is valid. No package was published.",
           evidence: %{command: ["mix", "hex.publish", "--yes"]}
         }}
    end
  end

  @impl true
  def execute(%Request{} = request, context) do
    run_dir = Artifacts.run_directory(context.repository, request.run_id)

    with {:ok, process} <-
           ProcessRunner.run("mix", ["hex.publish", "--yes"],
             cwd: context.repository.root,
             stdout_path: Path.join(run_dir, "logs/delivery-hex.stdout.log"),
             stderr_path: Path.join(run_dir, "logs/delivery-hex.stderr.log"),
             timeout_ms: context.timeout_ms,
             max_output_bytes: context.max_output_bytes
           ) do
      status = if process.status == "success", do: "confirmed", else: "uncertain"

      {:ok,
       %Result{
         status: status,
         message: "Hex publish ended with #{process.status}.",
         evidence: process
       }}
    end
  end

  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
