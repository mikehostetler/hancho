defmodule Hancho.Demand.Cache do
  @moduledoc "Apply-only local cache and audit history for demand synchronization."

  alias Hancho.Demand.Record

  @spec intent(Hancho.Project.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def intent(project, repository, actions) do
    append(project, %{
      "event" => "demand.sync.intent",
      "repository" => repository,
      "actions" => actions,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @spec receipt(Hancho.Project.t(), String.t(), [Record.t()], [String.t()]) ::
          :ok | {:error, term()}
  def receipt(project, repository, records, actions) do
    mapped =
      records
      |> Enum.filter(&(&1.mapping_status == "mapped"))
      |> Enum.map(&mapping/1)

    payload = %{
      "version" => 1,
      "repository" => repository,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "mappings" => mapped
    }

    with :ok <- atomic_write(cache_path(project), Jason.encode!(payload, pretty: true) <> "\n"),
         :ok <-
           append(project, %{
             "event" => "demand.sync.receipt",
             "repository" => repository,
             "actions" => actions,
             "mapping_count" => length(mapped),
             "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
           }) do
      :ok
    end
  end

  @spec cache_path(Hancho.Project.t()) :: String.t()
  def cache_path(project), do: Path.join(project.hancho_dir, "demand-mappings.json")

  @spec history_path(Hancho.Project.t()) :: String.t()
  def history_path(project), do: Path.join(project.logs_path, "demand-sync.jsonl")

  defp mapping(record) do
    %{
      "kind" => record.kind,
      "github_repository" => record.github_repository,
      "github_node_id" => record.github_node_id,
      "github_url" => record.github_url,
      "beadwork_id" => record.beadwork_id
    }
  end

  defp append(project, value) do
    path = history_path(project)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, file} <- File.open(path, [:append, :binary]),
         :ok <- IO.binwrite(file, Jason.encode!(value) <> "\n"),
         :ok <- :file.sync(file) do
      File.close(file)
    else
      {:error, reason} -> {:error, {:demand_history_write_failed, path, reason}}
    end
  end

  defp atomic_write(path, contents) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, contents, [:binary, :sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:demand_cache_write_failed, path, reason}}
    end
  end
end
