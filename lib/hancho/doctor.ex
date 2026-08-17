defmodule Hancho.Doctor do
  @moduledoc false

  @type check :: %{name: String.t(), status: :pass | :warning | :fail, detail: String.t()}

  def run(options \\ []) do
    cwd = Keyword.get(options, :cwd, File.cwd!())
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    git = Keyword.get(options, :git, Hancho.Git)
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    config_api = Keyword.get(options, :config_api, Hancho.Config)
    harness = Keyword.get(options, :harness, Jido.Harness)
    start_harness = Keyword.get(options, :start_harness, &Hancho.Harness.ensure_started/0)

    git_executable = git.executable()
    project_result = project_api.discover(cwd: cwd, git: git)
    git_status = git_status(git, project_result)
    beadwork_executable = beadwork.executable()
    beadwork_version = beadwork_version(beadwork, cwd, beadwork_executable)
    beadwork_config = beadwork_config(beadwork, project_result, beadwork_executable)
    config_result = config_result(config_api, project_result)
    harness_start = start_harness.()

    checks = [
      executable_check("git", git_executable),
      repository_check(project_result),
      branch_check(git_status),
      worktree_check(git_status),
      state_directory_check(project_result),
      config_check(config_result),
      executable_check("beadwork", beadwork_executable),
      beadwork_version_check(beadwork_version),
      beadwork_repository_check(beadwork_config),
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

  defp git_status(git, {:ok, project}), do: git.status(working_dir: project.root)
  defp git_status(_git, {:error, _reason}), do: {:error, :repository_unavailable}

  defp beadwork_version(_beadwork, _cwd, {:error, _reason}), do: {:error, :not_found}
  defp beadwork_version(beadwork, cwd, {:ok, _path}), do: beadwork.version(working_dir: cwd)

  defp beadwork_config(_beadwork, _project, {:error, _reason}), do: {:error, :not_found}

  defp beadwork_config(beadwork, {:ok, project}, {:ok, _path}) do
    beadwork.repository_config(working_dir: project.root)
  end

  defp beadwork_config(_beadwork, {:error, _reason}, {:ok, _path}),
    do: {:error, :repository_unavailable}

  defp config_result(config_api, {:ok, project}), do: config_api.load(project)
  defp config_result(_config_api, {:error, _reason}), do: {:error, :repository_unavailable}

  defp executable_check(name, {:error, :not_found}),
    do: check(name, :fail, "Executable not found in PATH.")

  defp executable_check(name, {:ok, path}), do: check(name, :pass, path)

  defp repository_check({:error, _reason}),
    do: check("repository", :fail, "Current directory is not in a Git repository.")

  defp repository_check({:ok, project}), do: check("repository", :pass, project.root)

  defp branch_check({:ok, %{branch: branch}}) when branch in [nil, "HEAD (no branch)"],
    do: check("branch", :warning, "HEAD is detached.")

  defp branch_check({:ok, %{branch: branch}}), do: check("branch", :pass, branch)
  defp branch_check({:error, reason}), do: check("branch", :fail, format_reason(reason))

  defp worktree_check({:ok, %{entries: []}}), do: check("worktree", :pass, "clean")

  defp worktree_check({:ok, %{entries: _entries}}),
    do: check("worktree", :warning, "uncommitted changes")

  defp worktree_check({:error, reason}), do: check("worktree", :fail, format_reason(reason))

  defp state_directory_check({:error, _reason}),
    do: check("state", :warning, "Repository is not available.")

  defp state_directory_check({:ok, project}) do
    if File.dir?(project.hancho_dir) do
      check("state", :pass, project.hancho_dir)
    else
      check("state", :warning, "#{project.hancho_dir} does not exist.")
    end
  end

  defp config_check({:ok, config}) do
    logs =
      if config.logs.enabled do
        "#{config.logs.format} logs at .hancho/logs/#{config.logs.path}"
      else
        "logs disabled"
      end

    check("config", :pass, "version #{config.version}, repo #{config.repo.path}, #{logs}")
  end

  defp config_check({:error, %Hancho.Config.Error{} = error}),
    do: check("config", :fail, error.message)

  defp config_check({:error, reason}), do: check("config", :fail, format_reason(reason))

  defp beadwork_version_check({:ok, version}),
    do: check("beadwork_version", :pass, version)

  defp beadwork_version_check({:error, reason}),
    do: check("beadwork_version", :fail, format_reason(reason, "Beadwork is not available."))

  defp beadwork_repository_check({:ok, config}) do
    detail = config |> String.split("\n", trim: true) |> Enum.join(", ")
    check("beadwork_repository", :pass, detail)
  end

  defp beadwork_repository_check({:error, _reason}),
    do: check("beadwork_repository", :fail, "Not initialized. Run 'bw init'.")

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

  defp format_reason(:not_found, fallback), do: fallback
  defp format_reason(reason, _fallback), do: format_reason(reason)
  defp format_reason(reason), do: inspect(reason)

  defp check(name, status, detail), do: %{name: name, status: status, detail: detail}

  defp join(values), do: values |> Enum.map(&to_string/1) |> Enum.join(", ")
end
