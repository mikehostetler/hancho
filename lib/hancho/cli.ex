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

  def main(args) do
    case run(args) do
      0 -> :ok
      status -> System.halt(status)
    end
  end

  def run(args, options \\ [])

  def run([], _options) do
    IO.puts(@usage)
    0
  end

  def run([flag], _options) when flag in ["--help", "-h", "help"] do
    IO.puts(@usage)
    0
  end

  def run([flag], _options) when flag in ["--version", "-v", "version"] do
    IO.puts(Hancho.version())
    0
  end

  def run(["doctor"], options) do
    report = Hancho.Doctor.run(options)
    IO.puts(Hancho.Doctor.format(report))

    if report.healthy?, do: 0, else: 1
  end

  def run(["init"], options) do
    case Hancho.Init.run(options) do
      {:ok, path} ->
        IO.puts("Initialized Hancho at #{path}")
        0

      {:error, message} ->
        IO.puts(:stderr, "ERROR: #{message}")
        1
    end
  end

  def run(args, _options) do
    IO.puts(:stderr, "ERROR: Unknown command: #{Enum.join(args, " ")}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end
end
