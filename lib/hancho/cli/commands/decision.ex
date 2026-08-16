defmodule Hancho.CLI.Commands.Decision do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Operations, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([answer, decision_id, "--reason", reason], options)
      when answer in ["approved", "rejected"] and reason != "" do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, decision} <- Operations.decide(repository, decision_id, answer, actor(), reason) do
      %Result{
        data: %{result: answer, decision: decision},
        text: "#{decision_id} #{answer} by #{decision["actor"]}: #{decision["reason"]}"
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute([answer | _args], _options) do
    command = if answer == "approved", do: "approve", else: "reject"

    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho #{command} DECISION_ID --reason TEXT"
  end

  defp actor, do: System.get_env("USER") || "local-user"
end
