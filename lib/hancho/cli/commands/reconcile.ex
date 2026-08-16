defmodule Hancho.CLI.Commands.Reconcile do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Reconciler, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([run_id], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, data} <- Reconciler.reconcile_run(repository, run_id) do
      text = "Reconciled #{length(data.effects)} effects. Unresolved: #{data.unresolved}."

      %Result{
        data: Map.put(data, :result, if(data.unresolved == 0, do: "ok", else: "uncertain")),
        text: text,
        status: if(data.unresolved == 0, do: 0, else: 75)
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho reconcile RUN_ID"
  end
end
