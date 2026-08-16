defmodule Hancho.CLI.Commands.Close do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Closure, Error, Repository}

  @impl true
  def execute([run_id, "--result", receiver_result | args], options) do
    close_options = parse(args, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- Closure.close(repository, run_id, receiver_result, close_options) do
      %Result{
        data: Map.put(outcome, :result, "closed"),
        text: "Closed work records after receiver acceptance for #{run_id}."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()
  defp parse([], options), do: options

  defp parse(["--delivery-required" | rest], options),
    do: parse(rest, Keyword.put(options, :delivery_required, true))

  defp parse(["--learning", learning | rest], options),
    do: parse(rest, Keyword.put(options, :learning, learning))

  defp parse(["--expected-result", result | rest], options),
    do: parse(rest, Keyword.put(options, :expected_result, result))

  defp parse(_args, _options), do: invalid!()

  defp invalid!,
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message:
          "Usage: hancho close RUN_ID --result TEXT [--delivery-required] [--learning TEXT]"
      )
end
