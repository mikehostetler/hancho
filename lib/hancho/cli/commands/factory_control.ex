defmodule Hancho.CLI.Commands.FactoryControl do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Factory.Client
  alias Hancho.{Error, Repository}

  @impl true
  def execute([command | args], options) when command in ["down", "pause", "continue"] do
    arguments = parse(command, args)

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, status} <- Client.request(repository, command, arguments) do
      %Result{data: Map.put(status, "result", command), text: text(command, status)}
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho down [--force] | hancho pause | hancho continue"
  end

  defp parse("down", []), do: %{"force" => false}
  defp parse("down", ["--force"]), do: %{"force" => true}
  defp parse(command, []) when command in ["pause", "continue"], do: %{}

  defp parse(_command, _args) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Invalid factory control options."
  end

  defp text(command, status), do: "Factory #{command}: #{status["state"]}."
end
