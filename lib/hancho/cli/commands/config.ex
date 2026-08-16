defmodule Hancho.CLI.Commands.Config do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Config, Error, JSON, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([action], options) when action in ["show", "validate"] do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, config} <- Config.load(repository) do
      case action do
        "show" ->
          data = Map.put(Config.safe_view(config), :result, "ok")
          %Result{data: data, text: JSON.encode!(data)}

        "validate" ->
          data = %{result: "ok", config_hash: config.hash, source: config.path}

          %Result{
            data: data,
            text: "Configuration is valid. Hash: #{config.hash}. Source: #{config.path}."
          }
      end
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho config show|validate [--repo PATH]"
  end
end
