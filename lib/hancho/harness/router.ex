defmodule Hancho.Harness.Router do
  @moduledoc "Resolves workflow capabilities to configured harness adapters."

  alias Hancho.Harness.{Codex, External, Fake, Grok}
  alias Hancho.{Error, Repository}

  @spec resolve(map(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(config, definition, station_id) do
    with {:ok, station} <- fetch_station(definition, station_id),
         {:ok, harness_name} <- fetch_route(config.data, definition.name, station_id),
         {:ok, harness_config} <- fetch_harness(config.data, harness_name),
         :ok <- require_capability(harness_name, harness_config, station.capability),
         {:ok, module} <- adapter_module(harness_config["adapter"]) do
      {:ok,
       %{
         name: harness_name,
         module: module,
         config: harness_config,
         station: station,
         config_hash: config.hash
       }}
    end
  end

  @spec list(map()) :: [map()]
  def list(config) do
    Enum.map(config.data["harnesses"] || %{}, fn {name, harness} ->
      %{
        name: name,
        adapter: harness["adapter"],
        command: harness["command"],
        capabilities: harness["capabilities"] || []
      }
    end)
  end

  @spec doctor(map(), Repository.t(), String.t() | nil) :: [map()]
  def doctor(config, repository, selected \\ nil) do
    config
    |> list()
    |> Enum.filter(&(is_nil(selected) or &1.name == selected))
    |> Enum.map(fn harness ->
      full = config.data["harnesses"][harness.name] |> Map.put("repository_path", repository.root)

      with {:ok, module} <- adapter_module(harness.adapter),
           {:ok, detail} <- module.doctor(full),
           {:ok, version} <- module.version(full) do
        Map.merge(harness, %{status: "pass", detail: detail, version: version})
      else
        {:error, error} -> Map.merge(harness, %{status: "fail", detail: Exception.message(error)})
      end
    end)
  end

  @spec validate_routes(map(), [map()]) :: :ok | {:error, Error.t()}
  def validate_routes(config, definitions) do
    errors =
      Enum.flat_map(definitions, fn definition ->
        Enum.flat_map(definition.stations, fn {station_id, _station} ->
          case resolve(config, definition, station_id) do
            {:ok, _} -> []
            {:error, error} -> [error.message]
          end
        end)
      end)

    if errors == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_routes,
         exit_status: 78,
         message: Enum.join(errors, "; "),
         details: %{errors: errors}
       }}
    end
  end

  defp fetch_station(definition, station_id) do
    case Map.fetch(definition.stations, station_id) do
      {:ok, station} ->
        {:ok, station}

      :error ->
        {:error,
         error(:unknown_station, "Workflow '#{definition.name}' has no station '#{station_id}'.")}
    end
  end

  defp fetch_route(config, workflow, station) do
    case get_in(config, ["routes", workflow, station]) do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        {:error, error(:missing_route, "Station '#{workflow}.#{station}' has no harness route.")}
    end
  end

  defp fetch_harness(config, name) do
    case get_in(config, ["harnesses", name]) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, error(:unknown_harness, "Harness '#{name}' is not configured.")}
    end
  end

  defp require_capability(name, config, capability) do
    if capability in (config["capabilities"] || []) do
      :ok
    else
      {:error,
       error(:missing_capability, "Harness '#{name}' does not supply capability '#{capability}'.")}
    end
  end

  defp adapter_module("builtin:fake"), do: {:ok, Fake}
  defp adapter_module("builtin:grok"), do: {:ok, Grok}
  defp adapter_module("builtin:codex"), do: {:ok, Codex}
  defp adapter_module(adapter) when is_binary(adapter) and adapter != "", do: {:ok, External}

  defp adapter_module(_adapter),
    do: {:error, error(:unknown_adapter, "Harness adapter is not valid.")}

  defp error(code, message), do: %Error{code: code, exit_status: 78, message: message}
end
