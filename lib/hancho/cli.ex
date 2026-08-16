defmodule Hancho.CLI do
  @moduledoc false

  def main(args) do
    case run(args) do
      0 -> :ok
      status -> System.halt(status)
    end
  end

  def run(args, options \\ [])

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

  def run(_args, _options) do
    IO.puts(Hancho.version())
    0
  end
end
