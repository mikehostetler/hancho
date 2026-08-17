defmodule Hancho.Workflow.Loader do
  @moduledoc "Loads workflow definitions from the repository-local YAML folder."

  alias Hancho.Workflow.Definition

  @spec load(Hancho.Project.t(), String.t()) :: {:ok, Definition.t()} | {:error, term()}
  def load(project, name) when is_binary(name) do
    case load_with_source(project, name) do
      {:ok, definition, _source} -> {:ok, definition}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_with_source(Hancho.Project.t(), String.t()) ::
          {:ok, Definition.t(), map()} | {:error, term()}
  def load_with_source(project, name) when is_binary(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) do
      load_path_with_source(Path.join(project.workflows_path, name <> ".yaml"))
    else
      {:error, "Invalid workflow name: #{name}"}
    end
  end

  @spec load_path(String.t()) :: {:ok, Definition.t()} | {:error, term()}
  def load_path(path) do
    case load_path_with_source(path) do
      {:ok, definition, _source} -> {:ok, definition}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_path_with_source(String.t()) :: {:ok, Definition.t(), map()} | {:error, term()}
  def load_path_with_source(path) do
    with {:ok, yaml} <- File.read(path),
         {:ok, values} <- YamlElixir.read_from_string(yaml),
         {:ok, definition} <- Definition.new(values) do
      {:ok, definition,
       %{
         path: Path.expand(path),
         yaml: yaml,
         sha256: sha256(yaml)
       }}
    else
      {:error, :enoent} -> {:error, "Workflow file not found: #{path}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
