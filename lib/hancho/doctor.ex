defmodule Hancho.Doctor do
  @moduledoc false

  @type check :: %{name: String.t(), status: :pass | :warning | :fail, detail: String.t()}

  def run(options \\ []) do
    cwd = Keyword.get(options, :cwd, File.cwd!())
    find_executable = Keyword.get(options, :find_executable, &System.find_executable/1)
    command = Keyword.get(options, :command, &System.cmd/3)
    harness = Keyword.get(options, :harness, Jido.Harness)
    start_harness = Keyword.get(options, :start_harness, &Hancho.Harness.ensure_started/0)

    git = find_executable.("git")
    beadwork = find_executable.("bw")
    repository = repository_root(git, cwd, command)
    harness_start = start_harness.()

    checks = [
      executable_check("git", git),
      repository_check(repository),
      branch_check(git, repository, command),
      worktree_check(git, repository, command),
      state_directory_check(repository),
      executable_check("beadwork", beadwork),
      beadwork_version_check(beadwork, cwd, command),
      beadwork_repository_check(beadwork, repository, command),
      harness_check(harness, harness_start),
      harness_provider_check(harness, harness_start)
    ]

    %{healthy?: Enum.all?(checks, &(&1.status != :fail)), checks: checks}
  end

  def format(report) do
    lines =
      Enum.map(report.checks, fn check ->
        "#{check.status |> Atom.to_string() |> String.upcase()} #{check.name}: #{check.detail}"
      end)

    Enum.join(["Hancho doctor" | lines], "\n")
  end

  defp executable_check(name, nil),
    do: check(name, :fail, "Executable not found in PATH.")

  defp executable_check(name, path), do: check(name, :pass, path)

  defp repository_root(nil, _cwd, _command), do: nil

  defp repository_root(git, cwd, command) do
    case run_command(command, git, ["rev-parse", "--show-toplevel"], cwd) do
      {:ok, root} -> root
      {:error, _detail} -> nil
    end
  end

  defp repository_check(nil),
    do: check("repository", :fail, "Current directory is not in a Git repository.")

  defp repository_check(root), do: check("repository", :pass, root)

  defp branch_check(_git, nil, _command),
    do: check("branch", :fail, "Repository is not available.")

  defp branch_check(git, repository, command) do
    case run_command(command, git, ["branch", "--show-current"], repository) do
      {:ok, ""} -> check("branch", :warning, "HEAD is detached.")
      {:ok, branch} -> check("branch", :pass, branch)
      {:error, detail} -> check("branch", :fail, detail)
    end
  end

  defp worktree_check(_git, nil, _command),
    do: check("worktree", :fail, "Repository is not available.")

  defp worktree_check(git, repository, command) do
    case run_command(command, git, ["status", "--porcelain"], repository) do
      {:ok, ""} -> check("worktree", :pass, "clean")
      {:ok, _changes} -> check("worktree", :warning, "uncommitted changes")
      {:error, detail} -> check("worktree", :fail, detail)
    end
  end

  defp state_directory_check(nil),
    do: check("state", :warning, "Repository is not available.")

  defp state_directory_check(repository) do
    path = Path.join(repository, ".hancho")

    if File.dir?(path) do
      check("state", :pass, path)
    else
      check("state", :warning, "#{path} does not exist.")
    end
  end

  defp beadwork_version_check(nil, _cwd, _command),
    do: check("beadwork_version", :fail, "Beadwork is not available.")

  defp beadwork_version_check(beadwork, cwd, command) do
    case run_command(command, beadwork, ["--version"], cwd) do
      {:ok, version} -> check("beadwork_version", :pass, version)
      {:error, detail} -> check("beadwork_version", :fail, detail)
    end
  end

  defp beadwork_repository_check(nil, _repository, _command),
    do: check("beadwork_repository", :fail, "Beadwork is not available.")

  defp beadwork_repository_check(_beadwork, nil, _command),
    do: check("beadwork_repository", :fail, "Repository is not available.")

  defp beadwork_repository_check(beadwork, repository, command) do
    case run_command(command, beadwork, ["config", "list"], repository) do
      {:ok, config} ->
        detail = config |> String.split("\n", trim: true) |> Enum.join(", ")
        check("beadwork_repository", :pass, detail)

      {:error, _detail} ->
        check("beadwork_repository", :fail, "Not initialized. Run 'bw init'.")
    end
  end

  defp harness_check(harness, :ok) do
    check("jido_harness", :pass, "version #{harness.version()}")
  rescue
    error -> check("jido_harness", :fail, Exception.message(error))
  end

  defp harness_check(_harness, {:error, reason}) do
    check("jido_harness", :fail, inspect(reason))
  end

  defp harness_provider_check(_harness, {:error, _reason}) do
    check("cli_agents", :fail, "Jido.Harness did not start.")
  end

  defp harness_provider_check(harness, :ok) do
    providers = Enum.map(harness.providers(), & &1.provider)

    ready =
      Enum.filter(providers, fn provider ->
        case harness.status(provider) do
          {:ok, %{smoke_ready: true}} -> true
          _result -> false
        end
      end)

    if ready == [] do
      check("cli_agents", :warning, "No provider is ready. Supported: #{join(providers)}")
    else
      check("cli_agents", :pass, "Ready: #{join(ready)}")
    end
  rescue
    error -> check("cli_agents", :fail, Exception.message(error))
  catch
    kind, reason -> check("cli_agents", :fail, "#{kind}: #{inspect(reason)}")
  end

  defp run_command(command, executable, arguments, cwd) do
    case command.(executable, arguments, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp check(name, status, detail), do: %{name: name, status: status, detail: detail}

  defp join(values), do: values |> Enum.map(&to_string/1) |> Enum.join(", ")
end
