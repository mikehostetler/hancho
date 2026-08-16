defmodule Hancho.CLI.Commands.Deliver do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Delivery.Request
  alias Hancho.{Delivery, Error, Repository}

  @impl true
  def execute([run_id, adapter, artifact, environment | args], options) do
    parsed = parse(args, %{checks: [], secret_env: [], arguments: [], dry_run: true})

    request = %Request{
      run_id: run_id,
      adapter: adapter,
      artifact: artifact,
      target_environment: environment,
      authority: parsed[:authority],
      checks: Enum.reverse(parsed.checks),
      recovery_method: parsed[:recovery],
      secret_env: Enum.reverse(parsed.secret_env),
      options: %{"command" => parsed[:command], "arguments" => Enum.reverse(parsed.arguments)}
    }

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <-
           Delivery.run(repository, request, dry_run: parsed.dry_run, opt_in: not parsed.dry_run) do
      %Result{
        data: Map.put(outcome, :result, outcome.result.status),
        text:
          "Delivery #{if parsed.dry_run, do: "dry-run", else: "effect"}: #{outcome.result.status}. #{outcome.result.message}"
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()
  defp parse([], parsed), do: parsed

  defp parse(["--authority", value | rest], parsed),
    do: parse(rest, Map.put(parsed, :authority, value))

  defp parse(["--check", value | rest], parsed),
    do: parse(rest, Map.update!(parsed, :checks, &[value | &1]))

  defp parse(["--recovery", value | rest], parsed),
    do: parse(rest, Map.put(parsed, :recovery, value))

  defp parse(["--secret-env", value | rest], parsed),
    do: parse(rest, Map.update!(parsed, :secret_env, &[value | &1]))

  defp parse(["--command", value | rest], parsed),
    do: parse(rest, Map.put(parsed, :command, value))

  defp parse(["--arg", value | rest], parsed),
    do: parse(rest, Map.update!(parsed, :arguments, &[value | &1]))

  defp parse(["--confirm" | rest], parsed), do: parse(rest, Map.put(parsed, :dry_run, false))
  defp parse(["--dry-run" | rest], parsed), do: parse(rest, Map.put(parsed, :dry_run, true))
  defp parse(_args, _parsed), do: invalid!()

  defp invalid!,
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message:
          "Usage: hancho deliver RUN_ID ADAPTER ARTIFACT ENV --authority TEXT --check TEXT --recovery TEXT [--dry-run|--confirm]"
      )
end
