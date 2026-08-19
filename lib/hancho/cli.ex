defmodule Hancho.CLI do
  @moduledoc false

  @usage """
  Hancho manages a software factory for one Git repository.

  Usage:
    hancho init       Initialize Hancho in the current repository
    hancho doctor     Inspect the repository and local tools
    hancho run WORKFLOW ISSUE_ID [--verbose]
                      Run one Beadwork workflow in the foreground
    hancho run inspect RUN_ID
                      Inspect durable workflow and step state
    hancho retry RUN_ID [--verbose]
                      Continue one stopped workflow from its failed step
    hancho resume QUEUE_ID [--verbose]
                      Continue one stopped queue from its failed child
    hancho worktrees list
                      List retained Hancho worktrees and storage use
    hancho worktrees inspect RUN_ID
                      Inspect one retained worktree
    hancho worktrees clean RUN_ID
                      Remove generated artifacts from one retained worktree
    hancho queue WORKFLOW --source beadwork-ready --count N [--dry-run] [--verbose]
                      Run ready Beadwork tasks serially in the foreground
    hancho --version  Print the Hancho version
    hancho --help     Print this help
  """

  @switches [
    help: :boolean,
    version: :boolean,
    source: :string,
    count: :integer,
    verbose: :boolean,
    dry_run: :boolean
  ]
  @aliases [h: :help, v: :version]

  def main(args) do
    case run(args) do
      0 -> :ok
      status -> System.stop(status)
    end
  end

  def run(args, options \\ []) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {_parsed, _arguments, [invalid | _rest]} ->
        invalid_option(invalid)

      {parsed, arguments, []} ->
        dispatch(parsed, arguments, options)
    end
  end

  defp dispatch(parsed, arguments, options) do
    cond do
      parsed[:help] -> print_usage()
      parsed[:version] -> print_version()
      true -> dispatch_command(arguments, parsed, options)
    end
  end

  defp dispatch_command([], [], _options), do: print_usage()
  defp dispatch_command(["help"], [], _options), do: print_usage()
  defp dispatch_command(["version"], [], _options), do: print_version()

  defp dispatch_command(["doctor"], [], options) do
    report = Hancho.Doctor.run(options)
    IO.puts(Hancho.Doctor.format(report))

    if report.healthy?, do: 0, else: 1
  end

  defp dispatch_command(["init"], [], options) do
    case Hancho.Init.run(options) do
      {:ok, path} ->
        IO.puts("Initialized Hancho at #{path}")
        0

      {:error, message} ->
        IO.puts(:stderr, "ERROR: #{message}")
        1
    end
  end

  defp dispatch_command(["run", "inspect", run_id], [], options) do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    inspector = Keyword.get(options, :run_inspector, Hancho.Workflow.Inspector)
    cwd = Keyword.get(options, :cwd, File.cwd!())

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, report} <- inspector.inspect(project, run_id, options) do
      print_run_report(report)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["run", workflow, issue_id], parsed, options)
       when parsed == [] or parsed == [verbose: true] do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    runner = Keyword.get(options, :workflow_runner, Hancho.Workflow.Runner)
    cwd = Keyword.get(options, :cwd, File.cwd!())
    run_options = Keyword.put(options, :verbose, parsed[:verbose] || false)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, result} <-
           runner.run(
             project,
             workflow,
             %{"repo_path" => project.root, "issue_id" => issue_id},
             run_options
           ) do
      print_workflow_result(result)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["retry", run_id], parsed, options)
       when parsed == [] or parsed == [verbose: true] do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    runner = Keyword.get(options, :workflow_runner, Hancho.Workflow.Runner)
    cwd = Keyword.get(options, :cwd, File.cwd!())
    retry_options = Keyword.put(options, :verbose, parsed[:verbose] || false)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, result} <- runner.retry(project, run_id, retry_options) do
      print_workflow_result(result)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["resume", queue_id], parsed, options)
       when parsed == [] or parsed == [verbose: true] do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    runner = Keyword.get(options, :queue_runner, Hancho.Workflow.QueueRunner)
    cwd = Keyword.get(options, :cwd, File.cwd!())

    resume_options =
      options
      |> Keyword.put(:verbose, parsed[:verbose] || false)
      |> Keyword.put(:progress, fn message ->
        IO.puts(message)
        :ok
      end)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, result} <- runner.resume(project, queue_id, resume_options) do
      print_queue_result(result)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["worktrees", "list"], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, reports} <- worktrees_api(options).list(project, options) do
      print_worktree_list(reports)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["worktrees", "inspect", id], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, report} <- worktrees_api(options).inspect(project, id, options) do
      print_worktree(report)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["worktrees", "clean", id], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, result} <- worktrees_api(options).clean(project, id, options) do
      removed = if result.removed == [], do: "none", else: Enum.join(result.removed, ", ")
      IO.puts("Cleaned #{result.id}: #{removed}")
      IO.puts("Reclaimed: #{result.reclaimed_bytes} bytes")
      IO.puts("Source changes retained: yes")
      0
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["queue", workflow], parsed, options) do
    source = parsed[:source]
    count = parsed[:count]

    if is_binary(source) and is_integer(count) and count > 0 do
      project_api = Keyword.get(options, :project_api, Hancho.Project)
      runner = Keyword.get(options, :queue_runner, Hancho.Workflow.QueueRunner)
      cwd = Keyword.get(options, :cwd, File.cwd!())

      queue_options =
        options
        |> Keyword.put(:verbose, parsed[:verbose] || false)
        |> Keyword.put(:progress, fn message ->
          IO.puts(message)
          :ok
        end)

      with {:ok, project} <- project_api.discover(cwd: cwd),
           {:ok, result} <-
             run_or_preview(runner, project, workflow, source, count, parsed, queue_options) do
        print_queue_output(result, parsed[:dry_run] || false)
      else
        {:error, reason} ->
          IO.puts(:stderr, "ERROR: #{format_error(reason)}")
          1
      end
    else
      IO.puts(:stderr, "ERROR: queue requires --source and a positive --count.")
      2
    end
  end

  defp dispatch_command(_arguments, parsed, _options) when parsed != [] do
    options = parsed |> Keyword.keys() |> Enum.map_join(" ", &"--#{&1}")
    IO.puts(:stderr, "ERROR: Options are not valid for this command: #{options}")
    2
  end

  defp dispatch_command(arguments, _parsed, _options) do
    IO.puts(:stderr, "ERROR: Unknown command: #{Enum.join(arguments, " ")}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end

  defp run_or_preview(runner, project, workflow, source, count, parsed, options) do
    if parsed[:dry_run] do
      runner.preview(project, workflow, source, count, options)
    else
      runner.run(project, workflow, source, count, options)
    end
  end

  defp print_queue_output(preview, true) do
    count = length(preview.issues)
    noun = if count == 1, do: "task", else: "tasks"
    IO.puts("Dry run: #{preview.workflow} selected #{count} #{noun} from #{preview.source}.")
    IO.puts("Repository: #{preview.repository.branch} at #{preview.repository.head} (clean)")
    IO.puts("Retained worktrees: #{length(preview.repository.worktrees)}")
    IO.puts("Provider: #{preview.settings.provider || "not configured"}")
    IO.puts("Reasoning effort: #{preview.settings.reasoning_effort || "not configured"}")

    IO.puts(
      "Timeouts: implement #{format_milliseconds(preview.settings.implementation_timeout_ms)}, " <>
        "verify #{format_milliseconds(preview.settings.verification_timeout_ms)}"
    )

    Enum.each(preview.settings.repairs, fn repair ->
      noun = if repair.max_attempts == 1, do: "attempt", else: "attempts"

      IO.puts(
        "Repair: #{repair.step} via #{repair.provider}, #{repair.max_attempts} #{noun} " <>
          "(#{Enum.join(repair.codes, ", ")})"
      )
    end)

    preview.issues
    |> Enum.with_index(1)
    |> Enum.each(fn {issue, position} ->
      title = if is_binary(issue["title"]), do: " — #{issue["title"]}", else: ""
      IO.puts("#{position}. #{issue["id"]}#{title}")
    end)

    0
  end

  defp print_queue_output(result, false), do: print_queue_result(result)

  defp format_milliseconds(value) when is_integer(value), do: "#{value} ms"
  defp format_milliseconds(_value), do: "not configured"

  defp print_usage do
    IO.puts(@usage)
    0
  end

  defp print_version do
    IO.puts(Hancho.version())
    0
  end

  defp invalid_option({option, _value}) do
    IO.puts(:stderr, "ERROR: Unknown option: #{option}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end

  defp print_workflow_result(%Hancho.Workflow.Result{status: :completed} = result) do
    IO.puts("Workflow #{result.workflow} completed. Run: #{result.run_id}")
    0
  end

  defp print_workflow_result(%Hancho.Workflow.Result{status: :stopped} = result) do
    IO.puts(
      :stderr,
      "ERROR: Workflow #{result.workflow} stopped at #{result.current_step}: #{format_error(result.error)}"
    )

    if result.forensic_report, do: IO.puts(:stderr, "Forensic report: #{result.forensic_report}")

    1
  end

  defp print_queue_result(%Hancho.Workflow.QueueResult{status: :completed}), do: 0

  defp print_queue_result(%Hancho.Workflow.QueueResult{status: :stopped} = result) do
    IO.puts(
      :stderr,
      "ERROR: Queue #{result.queue_id} stopped at #{result.current_issue}: #{format_error(result.error)}"
    )

    if result.forensic_report, do: IO.puts(:stderr, "Forensic report: #{result.forensic_report}")

    1
  end

  defp print_run_report(report) do
    location = if report.current_step, do: " at #{report.current_step}", else: ""
    IO.puts("Run: #{report.run_id}")
    IO.puts("Workflow: #{report.workflow}")
    IO.puts("Status: #{report.status}#{location}")
    IO.puts("Started: #{report.started_at}")
    IO.puts("Finished: #{report.finished_at || "running"}")
    IO.puts("Duration: #{format_duration(report.duration_ms)}")
    print_provider(report.provider)
    print_verification(report.verification)
    IO.puts("Commit: #{report.commit || "none"}")
    IO.puts("Retained worktree: #{report.retained_worktree || "none"}")
    IO.puts("Forensic report: #{report.forensic_report || "none"}")
    if report.failure, do: IO.puts("Failure: #{format_error(report.failure)}")
    IO.puts("Steps:")

    Enum.each(report.steps, fn step ->
      IO.puts(
        "#{step.position + 1}. #{step.name}: #{step.status} (#{format_duration(step.duration_ms)})"
      )

      Enum.each(Map.get(step, :repairs, []), fn repair ->
        provider = repair["provider"] || "unknown provider"
        attempt = repair["attempt"] || "?"
        IO.puts("   Repair #{attempt}: #{repair["status"]} via #{provider}")
      end)
    end)

    0
  end

  defp print_worktree_list([]) do
    IO.puts("No retained Hancho worktrees.")
    0
  end

  defp print_worktree_list(reports) do
    Enum.each(reports, fn
      %{error: error} = report ->
        IO.puts("#{report.id}: error #{format_error(error)}")

      report ->
        state = if report.clean, do: "clean", else: "changed"
        IO.puts("#{report.id}: #{state}, #{report.size_bytes} bytes")
    end)

    0
  end

  defp print_worktree(report) do
    IO.puts("Worktree: #{report.id}")
    IO.puts("Path: #{report.path}")
    IO.puts("Registered: #{yes_no(report.registered)}")
    IO.puts("Detached: #{yes_no(report.detached)}")
    IO.puts("Head: #{report.head || "unknown"}")
    IO.puts("Status: #{if(report.clean, do: "clean", else: "changed")}")
    IO.puts("Size: #{report.size_bytes} bytes")
    IO.puts("Generated: #{report.generated_bytes} bytes")
    IO.puts("Changed paths: #{length(report.changed_paths)}")
    Enum.each(report.changed_paths, &IO.puts("- #{&1}"))
    0
  end

  defp discover_project(options) do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    project_api.discover(cwd: Keyword.get(options, :cwd, File.cwd!()))
  end

  defp worktrees_api(options), do: Keyword.get(options, :worktrees_api, Hancho.Worktrees)

  defp command_error(reason) do
    IO.puts(:stderr, "ERROR: #{format_error(reason)}")
    1
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_value), do: "no"

  defp print_provider(nil), do: IO.puts("Provider: not started")

  defp print_provider(provider) do
    identity = provider["harness_run_id"] || "unknown run"
    IO.puts("Provider: #{provider["provider"]} #{provider["status"]} (#{identity})")
  end

  defp print_verification(nil), do: IO.puts("Verification: not started")

  defp print_verification(verification) do
    summary = if verification.summary, do: " — #{verification.summary}", else: ""
    IO.puts("Verification: exit #{verification.exit_status}#{summary}")
    if verification.output_path, do: IO.puts("Verification output: #{verification.output_path}")
  end

  defp format_duration(value) when is_integer(value), do: "#{value} ms"
  defp format_duration(_value), do: "unknown"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
