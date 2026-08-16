defmodule Hancho.Artifacts do
  @moduledoc "Stores run artifacts as files and indexes them in SQLite."

  alias Hancho.{Clock, Error, ID, Repository, SQLite, Store}

  @directories ~w(prompts logs checks artifacts receipts reports)

  @spec prepare(Repository.t(), String.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def prepare(repository, run_id) do
    run_dir = run_directory(repository, run_id)
    File.mkdir_p!(run_dir)
    File.chmod!(run_dir, 0o700)

    Enum.each(@directories, fn directory ->
      path = Path.join(run_dir, directory)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end)

    {:ok, run_dir}
  rescue
    error in File.Error ->
      {:error,
       %Error{
         code: :artifact_directory_failed,
         exit_status: 73,
         message: Exception.message(error)
       }}
  end

  @spec write(Repository.t(), String.t(), String.t(), String.t(), iodata(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def write(repository, run_id, kind, name, content, options \\ []) do
    directory = directory_for(kind)

    with {:ok, run_dir} <- prepare(repository, run_id),
         {:ok, destination} <- safe_destination(run_dir, directory, name),
         :ok <- atomic_write(destination, content),
         {:ok, artifact} <- index(repository, run_id, kind, destination, options) do
      {:ok, artifact}
    end
  end

  @spec validate(Repository.t(), map()) :: :ok | {:error, Error.t()}
  def validate(repository, artifact) do
    path = Path.join(repository.runtime_dir, artifact["relative_path"])

    cond do
      not File.exists?(path) ->
        {:error,
         %Error{
           code: :artifact_missing,
           exit_status: 74,
           message: "Artifact '#{path}' is missing."
         }}

      hash_file(path) != artifact["content_hash"] ->
        {:error,
         %Error{
           code: :artifact_changed,
           exit_status: 74,
           message: "Artifact '#{path}' changed after it was indexed."
         }}

      true ->
        :ok
    end
  end

  @spec list(Repository.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(repository, run_id) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM artifacts WHERE run_id = #{SQLite.quote(run_id)} ORDER BY created_at, id;"
    )
  end

  @spec run_directory(Repository.t(), String.t()) :: Path.t()
  def run_directory(repository, run_id), do: Path.join([repository.runtime_dir, "runs", run_id])

  defp safe_destination(run_dir, directory, name) do
    destination = Path.expand(Path.join([run_dir, directory, name]))
    boundary = Path.expand(run_dir) <> "/"

    if String.starts_with?(destination, boundary) do
      {:ok, destination}
    else
      {:error,
       %Error{
         code: :artifact_path_escape,
         exit_status: 65,
         message: "Artifact path '#{name}' escapes its work-order folder."
       }}
    end
  end

  defp atomic_write(destination, content) do
    File.mkdir_p!(Path.dirname(destination))
    temporary = destination <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, content)
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, destination)
    :ok
  rescue
    error in File.Error ->
      {:error,
       %Error{code: :artifact_write_failed, exit_status: 74, message: Exception.message(error)}}
  end

  defp index(repository, run_id, kind, path, options) do
    id = ID.generate("artifact")
    relative = Path.relative_to(path, repository.runtime_dir)
    stat = File.stat!(path)
    now = Clock.utc_now()
    media_type = Keyword.get(options, :media_type, "application/octet-stream")
    retention = Keyword.get(options, :retention, "standard")
    hash = hash_file(path)

    sql = """
    INSERT INTO artifacts
      (id, run_id, kind, relative_path, content_hash, byte_size, media_type, retention_class, created_at)
    VALUES
      (#{q(id)}, #{q(run_id)}, #{q(kind)}, #{q(relative)}, #{q(hash)}, #{q(stat.size)}, #{q(media_type)}, #{q(retention)}, #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, [artifact]} <-
           SQLite.query(Store.path(repository), "SELECT * FROM artifacts WHERE id = #{q(id)};") do
      {:ok, artifact}
    end
  end

  defp directory_for("prompt"), do: "prompts"
  defp directory_for("log"), do: "logs"
  defp directory_for("check"), do: "checks"
  defp directory_for("receipt"), do: "receipts"
  defp directory_for("report"), do: "reports"
  defp directory_for(_kind), do: "artifacts"

  defp hash_file(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  defp q(value), do: SQLite.quote(value)
end
