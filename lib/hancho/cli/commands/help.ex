defmodule Hancho.CLI.Commands.Help do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result

  @help """
  Hancho coordinates a local software factory.

  Usage:
    hancho init [--repo PATH]
    hancho doctor [--repo PATH]
    hancho config show [--repo PATH]
    hancho config validate [--repo PATH]
    hancho workflow list
    hancho workflow show NAME
    hancho workflow validate NAME
    hancho work ready [--only ID] [--start-at ID] [--end-at ID] [--max N] [--include-blocked] [--include-closed] [--dry-run]
    hancho harness list [--repo PATH]
    hancho harness doctor [NAME] [--repo PATH]
    hancho guidance show WORKFLOW STATION [--design] [--repo PATH]
    hancho up [--tmux|-d] [--repo PATH]
    hancho down [--force] [--repo PATH]
    hancho pause | continue | status | queue [--repo PATH]
    hancho attach [--repo PATH]
    hancho run WORKFLOW WORK_REF [--detach] [--spec FILE] [--model NAME] [--repo PATH]
    hancho runs [--repo PATH]
    hancho show RUN_ID [--repo PATH]
    hancho logs [--run RUN_ID] [--station ID] [--since 30m] [--raw] [--follow]
    hancho decisions [--repo PATH]
    hancho approve DECISION_ID --reason TEXT
    hancho reject DECISION_ID --reason TEXT
    hancho cancel RUN_ID --reason TEXT
    hancho resume RUN_ID
    hancho reconcile RUN_ID
    hancho publish RUN_ID [--remote NAME] [--branch NAME]
    hancho pr RUN_ID [--base BRANCH] [--branch BRANCH]
    hancho merge RUN_ID PR [--revalidated-target SHA]
    hancho deliver RUN_ID ADAPTER ARTIFACT ENV --authority TEXT --check TEXT --recovery TEXT [--dry-run|--confirm]
    hancho close RUN_ID --result TEXT [--delivery-required] [--learning TEXT]
    hancho cleanup [--apply]
    hancho measures
    hancho kaizen list | hancho kaizen evaluate ID --result TEXT
    hancho version
    hancho help

  Global options:
    --json       Print stable JSON output.
    --debug      Show an unexpected Elixir exception.
    --repo PATH  Use this Git checkout instead of the current directory.
  """

  @impl true
  def execute(_args, _options) do
    %Result{data: %{result: "ok", help: @help}, text: @help}
  end
end
