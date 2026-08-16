defmodule Hancho.CLI do
  @moduledoc false

  def main(_args) do
    IO.puts(Hancho.version())
  end
end
