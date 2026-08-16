defmodule Hancho.CLI.Router do
  @moduledoc false

  alias Hancho.CLI.Commands
  alias Hancho.Error

  @commands %{
    "attach" => Commands.Attach,
    "cancel" => Commands.Cancel,
    "close" => Commands.Close,
    "cleanup" => Commands.Cleanup,
    "config" => Commands.Config,
    "decision" => Commands.Decision,
    "deliver" => Commands.Deliver,
    "decisions" => Commands.Decisions,
    "doctor" => Commands.Doctor,
    "down" => Commands.FactoryControl,
    "help" => Commands.Help,
    "guidance" => Commands.Guidance,
    "harness" => Commands.Harness,
    "kaizen" => Commands.Kaizen,
    "init" => Commands.Init,
    "logs" => Commands.Logs,
    "merge" => Commands.Merge,
    "measures" => Commands.Measures,
    "pause" => Commands.FactoryControl,
    "pr" => Commands.PR,
    "publish" => Commands.Publish,
    "continue" => Commands.FactoryControl,
    "queue" => Commands.Queue,
    "reconcile" => Commands.Reconcile,
    "resume" => Commands.Resume,
    "run" => Commands.Run,
    "runs" => Commands.Runs,
    "show" => Commands.Show,
    "status" => Commands.Status,
    "up" => Commands.Up,
    "version" => Commands.Version,
    "workflow" => Commands.Workflow,
    "work" => Commands.Work
  }

  @spec public_commands() :: [String.t()]
  def public_commands do
    @commands
    |> Map.keys()
    |> List.delete("decision")
    |> Kernel.++(["approve", "reject"])
    |> Enum.sort()
  end

  def execute([], options), do: Commands.Help.execute([], options)

  def execute([command | args], options) when command in ["--help", "-h"],
    do: Commands.Help.execute(args, options)

  def execute([command | args], options) do
    {command, args} = normalize_alias(command, args)

    case Map.fetch(@commands, command) do
      {:ok, Commands.FactoryControl} ->
        Commands.FactoryControl.execute([command | args], options)

      {:ok, module} ->
        module.execute(args, options)

      :error ->
        raise Error,
          code: :unknown_command,
          exit_status: 64,
          message: "Unknown command '#{command}'. Run 'hancho help'."
    end
  end

  defp normalize_alias("approve", args), do: {"decision", ["approved" | args]}
  defp normalize_alias("reject", args), do: {"decision", ["rejected" | args]}
  defp normalize_alias(command, args), do: {command, args}
end
