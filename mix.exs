defmodule Hancho.MixProject do
  use Mix.Project

  def project do
    [
      app: :hancho,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: Hancho.CLI, app: nil, include_priv_for: [:erlexec]],
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
      {:bedrock,
       github: "mikehostetler/bedrock", ref: "6d7aa745ee6b3376f260bba1bda8b3c4c34539c2"},
      {:erlexec, "~> 2.3.4", runtime: false},
      {:git, "~> 0.7.0"},
      {:jason, "~> 1.4"},
      {:jido_action, "~> 2.3"},
      {:jido_harness,
       github: "agentjido/jido_harness", ref: "e41fc1651282469f2db4219a48d9f7feef1b0dbc"},
      {:toml_elixir, "~> 3.1"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.18.7"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --cover --exclude subprocess",
        "cmd env MIX_ENV=test mix test --only subprocess",
        "cmd env MIX_ENV=prod mix escript.build",
        "cmd elixir scripts/escript_smoke.exs"
      ]
    ]
  end
end
