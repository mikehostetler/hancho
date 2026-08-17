defmodule Hancho.CLI do
  @moduledoc false

  @usage """
  Hancho manages a software factory for one Git repository.

  Usage:
    hancho init       Initialize Hancho in the current repository
    hancho doctor     Inspect the repository and local tools
    hancho --version  Print the Hancho version
    hancho --help     Print this help
  """

  @switches [help: :boolean, version: :boolean]
  @aliases [h: :help, v: :version]

  def main(args) do
    case run(args) do
      0 -> :ok
      status -> System.halt(status)
    end
  end

  def run(args, options \\ []) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {_parsed, _arguments, [invalid | _rest]} ->
        invalid_option(invalid)

      {parsed, arguments, []} ->
        dispatch(parsed, arguments, options)
    end
  end

  defp dispatch(parsed, arguments, options) do
    cond do
      parsed[:help] -> print_usage()
      parsed[:version] -> print_version()
      true -> dispatch_command(arguments, options)
    end
  end

  defp dispatch_command([], _options), do: print_usage()
  defp dispatch_command(["help"], _options), do: print_usage()
  defp dispatch_command(["version"], _options), do: print_version()

  defp dispatch_command(["doctor"], options) do
    report = Hancho.Doctor.run(options)
    IO.puts(Hancho.Doctor.format(report))

    if report.healthy?, do: 0, else: 1
  end

  defp dispatch_command(["init"], options) do
    case Hancho.Init.run(options) do
      {:ok, path} ->
        IO.puts("Initialized Hancho at #{path}")
        0

      {:error, message} ->
        IO.puts(:stderr, "ERROR: #{message}")
        1
    end
  end

  defp dispatch_command(arguments, _options) do
    IO.puts(:stderr, "ERROR: Unknown command: #{Enum.join(arguments, " ")}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end

  defp print_usage do
    IO.puts(@usage)
    0
  end

  defp print_version do
    IO.puts(Hancho.version())
    0
  end

  defp invalid_option({option, _value}) do
    IO.puts(:stderr, "ERROR: Unknown option: #{option}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end
end
