defmodule Hancho.MixProject do
  use Mix.Project

  def project do
    [
      app: :hancho,
      version: "0.1.0",
      elixir: "~> 1.20",
      escript: [main_module: Hancho.CLI]
    ]
  end

  def application do
    []
  end
end
