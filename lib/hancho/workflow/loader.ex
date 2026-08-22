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
         {:ok, definition} <- Definition.new(values),
         role_files? =
           Enum.any?(definition.roles, fn {_name, role} -> is_binary(role.prompt_file) end),
         {:ok, definition} <- resolve_role_prompts(definition, path),
         {:ok, snapshot} <- snapshot(definition, yaml, role_files?) do
      {:ok, definition,
       %{
         path: Path.expand(path),
         yaml: snapshot,
         sha256: sha256(snapshot),
         source_sha256: sha256(yaml)
       }}
    else
      {:error, :enoent} -> {:error, "Workflow file not found: #{path}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp snapshot(definition, _yaml, true),
    do: Jason.encode(Definition.to_map(definition), pretty: true)

  defp snapshot(_definition, yaml, false), do: {:ok, yaml}

  defp resolve_role_prompts(definition, workflow_path) do
    prompts_path = workflow_path |> Path.dirname() |> Path.join("../prompts") |> Path.expand()

    Enum.reduce_while(definition.roles, {:ok, %{}}, fn {name, role}, {:ok, roles} ->
      case resolve_role_prompt(role, prompts_path) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(roles, name, resolved)}}
        {:error, reason} -> {:halt, {:error, {:role_prompt_failed, name, reason}}}
      end
    end)
    |> case do
      {:ok, roles} -> {:ok, %{definition | roles: roles}}
      error -> error
    end
  end

  defp resolve_role_prompt(%{prompt: prompt} = role, _base) when is_binary(prompt),
    do: {:ok, role}

  defp resolve_role_prompt(%{prompt_file: file} = role, base) do
    with true <- Path.type(file) == :relative || {:error, :unsafe_path},
         {:ok, relative} <- Path.safe_relative(file, base),
         {:ok, prompt} <- File.read(Path.join(base, relative)) do
      {:ok, %{role | prompt: prompt, prompt_file: nil}}
    else
      :error -> {:error, :unsafe_path}
      {:error, reason} -> {:error, reason}
    end
  end
end
