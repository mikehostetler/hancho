defmodule Hancho.Host.Tmux do
  @moduledoc "Starts and attaches to the stable tmux session for one local factory."

  alias Hancho.Factory.Client
  alias Hancho.{Error, Repository}

  @spec session_name(Repository.t()) :: String.t()
  def session_name(repository) do
    base =
      repository.root
      |> Path.basename()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    suffix =
      :crypto.hash(:sha256, repository.root) |> Base.encode16(case: :lower) |> binary_part(0, 10)

    "hancho-#{base}-#{suffix}"
  end

  @spec start(Repository.t()) :: {:ok, map()} | {:error, Error.t()}
  def start(repository) do
    with {:ok, tmux} <- executable("tmux"),
         {:ok, hancho} <- hancho_executable(),
         false <- has_session?(tmux, session_name(repository)),
         {_output, 0} <-
           System.cmd(
             tmux,
             [
               "new-session",
               "-d",
               "-s",
               session_name(repository),
               hancho,
               "up",
               "--repo",
               repository.root,
               "--host",
               "tmux"
             ],
             stderr_to_stdout: true
           ),
         {:ok, status} <- wait_for_controller(repository, 100) do
      {:ok, Map.put(status, "session", session_name(repository))}
    else
      true ->
        if Client.running?(repository) do
          with {:ok, status} <- Client.request(repository, "status") do
            {:ok, Map.put(status, "session", session_name(repository))}
          end
        else
          {:error,
           error(
             :tmux_session_stale,
             "The tmux session exists, but no controller answered. Run 'tmux kill-session -t #{session_name(repository)}' after inspection."
           )}
        end

      {output, status} when is_integer(status) ->
        {:error,
         error(:tmux_start_failed, "tmux failed with status #{status}: #{String.trim(output)}")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec attach(Repository.t()) :: {:ok, :attached} | {:error, Error.t()}
  def attach(repository) do
    with {:ok, tmux} <- executable("tmux"),
         true <- has_session?(tmux, session_name(repository)),
         {_output, 0} <-
           System.cmd(tmux, ["attach-session", "-t", session_name(repository)],
             stderr_to_stdout: true
           ) do
      {:ok, :attached}
    else
      false ->
        {:error,
         error(
           :tmux_session_not_found,
           "No Hancho tmux session exists. Run 'hancho up --tmux'."
         )}

      {output, status} when is_integer(status) ->
        {:error, error(:tmux_attach_failed, "tmux attach failed: #{String.trim(output)}")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp has_session?(tmux, name) do
    match?({_output, 0}, System.cmd(tmux, ["has-session", "-t", name], stderr_to_stdout: true))
  end

  defp wait_for_controller(_repository, 0) do
    {:error,
     error(
       :factory_start_timeout,
       "The detached factory did not become healthy. Inspect it with 'hancho attach'."
     )}
  end

  defp wait_for_controller(repository, attempts) do
    case Client.request(repository, "status", %{}, 250) do
      {:ok, %{"health" => "healthy"} = status} ->
        {:ok, status}

      {:ok, status} ->
        {:error,
         error(
           :factory_unhealthy,
           "The detached factory started in '#{status["health"]}' health. Run 'hancho status'."
         )}

      {:error, _error} ->
        Process.sleep(100)
        wait_for_controller(repository, attempts - 1)
    end
  end

  defp hancho_executable do
    case System.get_env("HANCHO_EXECUTABLE") || escript_name() do
      nil ->
        {:error,
         error(
           :hancho_executable_unknown,
           "Set HANCHO_EXECUTABLE to the installed Hancho escript before detached startup."
         )}

      path ->
        {:ok, Path.expand(path)}
    end
  end

  defp escript_name do
    case :escript.script_name() do
      name when is_list(name) and name != [] -> List.to_string(name)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil ->
        {:error,
         error(
           :tmux_unavailable,
           "tmux is not available. Install tmux or run 'hancho up' in the foreground. Hancho does not use nohup."
         )}

      path ->
        {:ok, path}
    end
  end

  defp error(code, message), do: %Error{code: code, exit_status: 69, message: message}
end
