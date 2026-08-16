defmodule Hancho.MixProject do
  use Mix.Project

  def project do
    [
      app: :hancho,
      version: "0.1.0",
      elixir: "~> 1.20",
      escript: [main_module: Hancho.CLI, app: nil, include_priv_for: [:erlexec]],
      deps: deps()
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:erlexec, "~> 2.3.4", runtime: false},
      {:jason, "~> 1.4"},
      {:jido_harness,
       github: "agentjido/jido_harness", ref: "8bf0d52f4fed0d8a9d2594000d8b3a775da16f8b"},
      {:toml_elixir, "~> 3.1"},
      {:zoi, "~> 0.18.7"}
    ]
  end
end
