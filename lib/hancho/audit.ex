defmodule Hancho.Audit do
  @moduledoc "Provides best-effort audit delivery outside factory control flow."

  @spec open(Hancho.Project.t(), keyword()) :: {:ok, Hancho.Log.handle()}
  def open(project, options \\ []) do
    {console, log_options} = Keyword.pop(options, :console)

    result =
      with {:ok, config} <- Hancho.Config.load(project) do
        config =
          if is_boolean(console),
            do: %{config | logs: %{config.logs | console: console}},
            else: config

        Hancho.Log.open(project, config, log_options)
      end

    case result do
      {:ok, log} ->
        {:ok, log}

      {:error, reason} ->
        warn(:open, reason)
        {:ok, :disabled}
    end
  rescue
    error ->
      warn(:open, {:exception, error})
      {:ok, :disabled}
  catch
    kind, reason ->
      warn(:open, {kind, reason})
      {:ok, :disabled}
  end

  @spec write(Hancho.Log.handle(), iodata(), keyword()) :: :ok
  def write(log, message, options \\ []) do
    case Hancho.Log.write(log, message, options) do
      :ok -> :ok
      {:error, reason} -> warn(:write, reason)
    end
  rescue
    error -> warn(:write, {:exception, error})
  catch
    kind, reason -> warn(:write, {kind, reason})
  end

  @spec close(Hancho.Log.handle()) :: :ok
  def close(log) do
    Hancho.Log.close(log)
  rescue
    error -> warn(:close, {:exception, error})
  catch
    kind, reason -> warn(:close, {kind, reason})
  end

  defp warn(operation, reason) do
    Hancho.Log.internal(:warning, "Hancho audit #{operation} failed",
      audit_error: Hancho.Log.Event.normalize(reason)
    )

    :ok
  end
end
