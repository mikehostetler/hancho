defmodule Hancho.CLI.Commands.Up do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Factory.Controller
  alias Hancho.Host.Tmux
  alias Hancho.{Error, Repository}

  @impl true
  def execute(args, options) do
    parsed = parse(args, %{detached: false, host: "foreground"})

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())) do
      if parsed.detached do
        detached(repository)
      else
        foreground(repository, parsed.host, options)
      end
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  defp detached(repository) do
    case Tmux.start(repository) do
      {:ok, status} ->
        %Result{
          data: Map.put(status, "result", "started"),
          text: "Factory is active in tmux session #{status["session"]}."
        }

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp foreground(repository, host, options) do
    case Controller.start_link(repository, host: host, subscriber: self()) do
      {:ok, controller} ->
        monitor = Process.monitor(controller)
        install_signal_handlers()
        wait(controller, monitor, 0, Keyword.get(options, :json, false))

      {:error, %Error{} = error} ->
        raise error

      {:error, reason} ->
        raise Error,
          code: :factory_start_failed,
          exit_status: 73,
          message: "Factory startup failed: #{Exception.format_exit(reason)}"
    end
  end

  defp wait(controller, monitor, interrupts, json?) do
    receive do
      {:factory_event, message} ->
        unless json?, do: IO.puts("FACTORY: #{message}")
        wait(controller, monitor, interrupts, json?)

      :hancho_interrupt ->
        next = interrupts + 1
        Controller.stop(controller, next > 1)
        wait(controller, monitor, next, json?)

      {:DOWN, ^monitor, :process, ^controller, reason} ->
        status = if reason in [:normal, :shutdown], do: 0, else: 70

        %Result{
          data: %{
            result: if(status == 0, do: "stopped", else: "abnormal_stop"),
            reason: inspect(reason)
          },
          text: "Factory stopped (#{inspect(reason)}).",
          status: status
        }
    end
  end

  defp install_signal_handlers do
    owner = self()
    System.trap_signal(:sigterm, fn -> send(owner, :hancho_interrupt) end)
  end

  defp parse([], parsed), do: parsed

  defp parse([option | rest], parsed) when option in ["--tmux", "-d"],
    do: parse(rest, %{parsed | detached: true, host: "tmux"})

  defp parse(["--host", host | rest], parsed) when host in ["foreground", "tmux"],
    do: parse(rest, %{parsed | host: host})

  defp parse(_args, _parsed) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho up [--tmux|-d] [--repo PATH]"
  end
end
