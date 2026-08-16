defmodule Hancho.MixProject do
  use Mix.Project

  def project do
    [
      app: :hancho,
      version: "0.1.0",
      elixir: "~> 1.20.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Hancho.CLI, include_priv_for: [:erlexec]],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Hancho.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [{:check, :test}, {:"test.fast", :test}]]
  end

  defp aliases do
    [
      {:check, ["format --check-formatted", "compile --warnings-as-errors", "test"]},
      {:"test.fast", ["test --exclude integration --exclude acceptance"]}
    ]
  end

  defp deps do
    [
      {:erlexec, "~> 2.3.4", runtime: false},
      {:toml_elixir, "~> 3.1"},
      {:zoi, "~> 0.18.7"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
