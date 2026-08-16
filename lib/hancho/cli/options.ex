defmodule Hancho.CLI.Options do
  @moduledoc false

  alias Hancho.Error

  @spec parse!([String.t()]) :: {[String.t()], keyword()}
  def parse!(args), do: parse(args, [], [])

  defp parse([], clean, options), do: {Enum.reverse(clean), options}

  defp parse(["--json" | rest], clean, options),
    do: parse(rest, clean, Keyword.put(options, :json, true))

  defp parse(["--debug" | rest], clean, options),
    do: parse(rest, clean, Keyword.put(options, :debug, true))

  defp parse(["--repo", path | rest], clean, options) when path != "" and not is_nil(path),
    do: parse(rest, clean, Keyword.put(options, :repo, path))

  defp parse(["--repo" | _rest], _clean, _options) do
    raise Error,
      code: :missing_option_value,
      exit_status: 64,
      message: "Option '--repo' requires a path."
  end

  defp parse([arg | rest], clean, options), do: parse(rest, [arg | clean], options)
end
