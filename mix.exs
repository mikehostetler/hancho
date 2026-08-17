defmodule Hancho.MixProject do
  use Mix.Project

  def project do
    [
      app: :hancho,
      version: "0.1.0",
      elixir: "~> 1.20",
      escript: [main_module: Hancho.CLI, app: nil, include_priv_for: [:erlexec, :exqlite]],
      aliases: aliases(),
      test_coverage: [summary: [threshold: 65]],
      deps: deps()
    ]
  end

  def application do
    []
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  defp deps do
    [
      {:erlexec, "~> 2.3.4", runtime: false},
      {:exqlite, "~> 0.39"},
      {:git, "~> 0.7.0"},
      {:jason, "~> 1.4"},
      {:jido_action, "~> 2.3"},
      {:jido_harness,
       github: "agentjido/jido_harness", ref: "8bf0d52f4fed0d8a9d2594000d8b3a775da16f8b"},
      {:toml_elixir, "~> 3.1"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.18.7"}
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --cover",
        "escript.build",
        "cmd elixir scripts/escript_smoke.exs"
      ]
    ]
  end
end
