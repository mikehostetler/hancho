defmodule Hancho.CLI.Commands.Run do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.Factory.Client
  alias Hancho.{BuildRunner, Error, Repository, Runner}
  alias Hancho.CLI.Result

  @impl true
  def execute([workflow, work_ref | command_options], options) do
    run_options = parse_options(command_options, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- execute_run(repository, workflow, work_ref, run_options) do
      format_outcome(outcome)
    else
      {:error, %Error{} = error} -> raise error
      {:error, error} -> raise Error, code: :run_failed, exit_status: 75, message: inspect(error)
    end
  end

  def execute(args, _options) do
    if "--detach" in args do
      raise Error,
        code: :factory_not_active,
        exit_status: 69,
        message: "Detached submission needs an active factory. Run 'hancho up' first."
    else
      raise Error,
        code: :invalid_arguments,
        exit_status: 64,
        message: "Usage: hancho run WORKFLOW WORK_REF [--repo PATH]"
    end
  end

  defp run_workflow(repository, "build", work_ref, options),
    do: BuildRunner.run(repository, work_ref, options)

  defp run_workflow(repository, workflow, work_ref, options),
    do: Runner.run(repository, workflow, work_ref, options)

  defp execute_run(repository, workflow, work_ref, options) do
    if Keyword.get(options, :detach, false) do
      Client.request(repository, "submit", %{
        "workflow" => workflow,
        "work_ref" => work_ref,
        "options" => serializable_options(options)
      })
    else
      run_workflow(repository, workflow, work_ref, options)
    end
  end

  defp format_outcome(%{"accepted" => true, "item" => item}) do
    %Result{
      data: %{result: "accepted", item: item},
      text: "#{item["id"]} accepted #{item["workflow_name"]} #{item["work_ref"]}"
    }
  end

  defp format_outcome(%{work_order: work_order}) do
    %Result{
      data: %{result: work_order["status"], work_order: work_order},
      text:
        "#{work_order["id"]} #{work_order["workflow_name"]}.v#{work_order["workflow_version"]} #{work_order["state"]}",
      status: if(work_order["status"] == "complete", do: 0, else: 75)
    }
  end

  defp serializable_options(options) do
    %{
      "spec_path" => Keyword.get(options, :spec_path),
      "model" => Keyword.get(options, :model),
      "approvals" =>
        Keyword.get_values(options, :approval) ++ Keyword.get(options, :approvals, [])
    }
  end

  defp parse_options([], options), do: options

  defp parse_options(["--detach" | rest], options),
    do: parse_options(rest, Keyword.put(options, :detach, true))

  defp parse_options(["--spec", path | rest], options),
    do: parse_options(rest, Keyword.put(options, :spec_path, path))

  defp parse_options(["--approve-gate", _gate | _rest], _options) do
    raise Error,
      code: :durable_decision_required,
      exit_status: 64,
      message:
        "Inline gate approval is not permitted. Run the work, then use 'hancho approve DECISION_ID --reason TEXT'."
  end

  defp parse_options(["--model", model | rest], options),
    do: parse_options(rest, Keyword.put(options, :model, model))

  defp parse_options([option | _rest], _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Unknown run option '#{option}'."
  end
end
