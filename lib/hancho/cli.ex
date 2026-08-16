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

  def run(_args, _options) do
    IO.puts(Hancho.version())
    0
  end
end
