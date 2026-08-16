defmodule Hancho.CLI.Commands.Harness do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.Harness.Router
  alias Hancho.{Config, Error, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute(["list"], options) do
    {repository, config} = context!(options)
    harnesses = Router.list(config)

    text =
      Enum.map_join(
        harnesses,
        "\n",
        &"#{&1.name} adapter=#{&1.adapter} capabilities=#{Enum.join(&1.capabilities, ",")}"
      )

    %Result{data: %{result: "ok", repository: repository.root, harnesses: harnesses}, text: text}
  end

  def execute(["doctor"], options), do: doctor(options, nil)
  def execute(["doctor", name], options), do: doctor(options, name)

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho harness list|doctor [NAME] [--repo PATH]"
  end

  defp doctor(options, name) do
    {repository, config} = context!(options)
    results = Router.doctor(config, repository, name)

    if name && results == [] do
      raise Error,
        code: :unknown_harness,
        exit_status: 64,
        message: "Harness '#{name}' is not configured."
    end

    failed? = Enum.any?(results, &(&1.status == "fail"))

    text =
      Enum.map_join(
        results,
        "\n",
        &"#{String.upcase(&1.status)} #{&1.name}: #{inspect(&1.detail)}"
      )

    %Result{
      data: %{result: if(failed?, do: "failed", else: "ok"), harnesses: results},
      text: text,
      status: if(failed?, do: 69, else: 0)
    }
  end

  defp context!(options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, config} <- Config.load(repository) do
      {repository, config}
    else
      {:error, %Error{} = error} -> raise error
    end
  end
end
