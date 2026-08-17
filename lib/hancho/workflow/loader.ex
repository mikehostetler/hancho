defmodule Hancho.Workflow.Loader do
  @moduledoc "Loads workflow definitions from the repository-local YAML folder."

  alias Hancho.Workflow.Definition

  @spec load(Hancho.Project.t(), String.t()) :: {:ok, Definition.t()} | {:error, term()}
  def load(project, name) when is_binary(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) do
      load_path(Path.join(project.workflows_path, name <> ".yaml"))
    else
      {:error, "Invalid workflow name: #{name}"}
    end
  end

  @spec load_path(String.t()) :: {:ok, Definition.t()} | {:error, term()}
  def load_path(path) do
    with {:ok, values} <- YamlElixir.read_from_file(path),
         {:ok, definition} <- Definition.new(values) do
      {:ok, definition}
    else
      {:error, :enoent} -> {:error, "Workflow file not found: #{path}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
