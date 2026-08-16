defmodule Hancho.BuildFixture do
  import Hancho.RepositoryCase

  def project! do
    root = temporary_git_repository!("build")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(
      Path.join(root, "mix.exs"),
      """
      defmodule Fixture.MixProject do
        use Mix.Project
        def project, do: [app: :fixture, version: "0.1.0", elixir: "~> 1.20"]
        def application, do: []
      end
      """
    )

    File.write!(
      Path.join(root, ".formatter.exs"),
      "[inputs: [\"mix.exs\", \"{lib,test}/**/*.{ex,exs}\"]]\n"
    )

    File.write!(Path.join(root, ".gitignore"), "/.hancho/\n/_build/\n/deps/\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "."])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-q", "-m", "Add Mix fixture"])
    root
  end

  def phoenix_project! do
    root = project!()
    File.mkdir_p!(Path.join(root, "lib/fixture_web"))
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(root, "priv/repo/migrations"))

    File.write!(
      Path.join(root, "lib/fixture_web/endpoint.ex"),
      "defmodule FixtureWeb.Endpoint, do: :ok\n"
    )

    File.write!(Path.join(root, "config/runtime.exs"), "import Config\n")
    File.write!(Path.join(root, "priv/repo/migrations/.keep"), "")
    {_, 0} = System.cmd("git", ["-C", root, "add", "."])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-q", "-m", "Add private Phoenix shape"])
    root
  end

  def configure_adapter!(root, mode) do
    adapter_root = temporary_directory!("adapter")
    adapter = Path.join(adapter_root, "fixture-adapter")
    control_root = shell_single_quote(root)

    behavior = behavior(mode, control_root)

    File.write!(
      adapter,
      """
      #!/bin/sh
      case "$1" in
        doctor) printf '{"status":"pass"}\n' ;;
        version) printf '{"adapter_version":"1","harness_version":"fixture-1"}\n' ;;
        run)
          station=$(jq -r .station "$2")
          worktree=$(jq -r .worktree_path "$2")
          #{behavior}
          printf '{"type":"event","name":"fixture.completed"}\n'
          printf '{"type":"result","status":"success","session_id":"fixture-session","exit_status":0}\n'
          ;;
        *) exit 64 ;;
      esac
      """
    )

    File.chmod!(adapter, 0o700)

    config_path = Path.join(root, ".hancho/config.toml")
    config = File.read!(config_path)

    config =
      String.replace(config, "adapter = \"builtin:fake\"", "adapter = \"#{adapter}\"",
        global: false
      )

    config = String.replace(config, "command = \"fake\"", "command = \"fixture\"", global: false)
    File.write!(config_path, config)
    adapter
  end

  def spec(id, scopes \\ ["lib/"]) do
    %{
      "id" => id,
      "title" => "Add fixture module",
      "instructions" => "Add a small formatted Elixir module.",
      "allowed_scopes" => scopes,
      "profile" => "elixir_library",
      "checks" => [["true"], ["true"], ["true"]],
      "acceptance_conditions" => ["The project compiles and tests pass."]
    }
  end

  defp behavior(:success, _root) do
    ~s(if [ "$station" = implement ]; then mkdir -p "$worktree/lib"; printf 'defmodule Fixture.Added do\n  def value, do: :ok\nend\n' > "$worktree/lib/added.ex"; fi)
  end

  defp behavior(:scope_violation, _root) do
    behavior(:success, "") <>
      ~s(; if [ "$station" = implement ]; then printf 'outside\n' > "$worktree/outside.txt"; fi)
  end

  defp behavior(:commit, _root) do
    behavior(:success, "") <>
      ~s(; if [ "$station" = implement ]; then git -C "$worktree" add . && git -C "$worktree" commit -q -m 'Harness commit'; fi)
  end

  defp behavior(:repair, _root) do
    ~s(if [ "$station" = implement ]; then mkdir -p "$worktree/lib"; printf 'defmodule Fixture.Added do\n  this is invalid\nend\n' > "$worktree/lib/added.ex"; elif [ "$station" = repair ]; then printf 'defmodule Fixture.Added do\n  def value, do: :repaired\nend\n' > "$worktree/lib/added.ex"; fi)
  end

  defp behavior(:review_edit, _root) do
    behavior(:success, "") <>
      ~s(; if [ "$station" = review ]; then printf '\n# review mutation\n' >> "$worktree/lib/added.ex"; fi)
  end

  defp behavior(:gate, _root) do
    ~s(if [ "$station" = implement ]; then printf '\n# admitted dependency metadata change\n' >> "$worktree/mix.exs"; fi)
  end

  defp behavior(:target_change, root) do
    behavior(:success, "") <>
      "; if [ \"$station\" = implement ]; then printf 'target changed\\n' > '#{root}/target.txt'; git -C '#{root}' add target.txt; git -C '#{root}' commit -q -m 'Concurrent target change'; fi"
  end

  defp shell_single_quote(value), do: String.replace(value, "'", "'\\''")
end
