defmodule Hancho.Actions.RenderPrompt do
  @moduledoc "Renders and records one Markdown prompt for a later agent step."

  use Jido.Action,
    name: "hancho_render_prompt",
    description: "Renders an inline or repository-local Markdown prompt",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        prompt: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
        prompt_file: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
        context: Zoi.map() |> Zoi.default(%{})
      })

  @placeholder ~r/\{\{\s*([a-z][a-z0-9_]*(?:\.[A-Za-z0-9_-]+)*)\s*\}\}/

  @impl true
  def run(params, context) do
    with {:ok, source, prompt_file, template} <- template(params),
         {:ok, rendered} <- render(template, params.context),
         result <- snapshot(source, prompt_file, template, rendered),
         :ok <- audit(context, result) do
      {:ok, result}
    end
  end

  defp template(%{prompt: prompt, prompt_file: prompt_file})
       when is_binary(prompt) and is_binary(prompt_file),
       do: {:error, "Set either prompt or prompt_file, not both."}

  defp template(%{prompt: prompt}) when is_binary(prompt),
    do: {:ok, "inline", nil, prompt}

  defp template(%{prompt_file: prompt_file, repo_path: repository})
       when is_binary(prompt_file) do
    prompts_path = Path.join([repository, ".hancho", "prompts"])

    with {:ok, relative} <- safe_relative(prompt_file, prompts_path),
         path = Path.join(prompts_path, relative),
         {:ok, contents} <- File.read(path) do
      {:ok, "file", prompt_file, contents}
    else
      :error -> {:error, "The prompt file path is not safe: #{prompt_file}"}
      {:error, :enoent} -> {:error, "Prompt file not found: #{prompt_file}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp template(_params), do: {:error, "Set either prompt or prompt_file."}

  defp safe_relative(path, base) do
    if Path.type(path) == :relative, do: Path.safe_relative(path, base), else: :error
  end

  defp render(template, context) do
    @placeholder
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, template}, fn reference, {:ok, rendered} ->
      case fetch_context(context, String.split(reference, ".")) do
        {:ok, value} ->
          pattern = ~r/\{\{\s*#{Regex.escape(reference)}\s*\}\}/
          {:cont, {:ok, Regex.replace(pattern, rendered, stringify(value))}}

        :error ->
          {:halt, {:error, "Prompt variable was not found: {{#{reference}}}"}}
      end
    end)
  end

  defp fetch_context(value, []), do: {:ok, value}

  defp fetch_context(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_context(value, rest)
      :error -> fetch_atom_key(map, key, rest)
    end
  end

  defp fetch_context(_value, _path), do: :error

  defp fetch_atom_key(map, key, rest) do
    Enum.find_value(map, :error, fn
      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: fetch_context(value, rest), else: nil

      _pair ->
        nil
    end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(nil), do: ""
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp stringify(value), do: Jason.encode!(Hancho.Log.Event.normalize(value))

  defp snapshot(source, prompt_file, template, rendered) do
    %{
      source: source,
      prompt_file: prompt_file,
      template: template,
      template_sha256: sha256(template),
      rendered: rendered,
      sha256: sha256(rendered)
    }
  end

  defp audit(context, result) do
    Hancho.Audit.write(Map.get(context, :log, :disabled), "Prompt snapshot",
      event: "prompt.snapshot",
      metadata: Map.put(result, :step, Map.get(context, :step))
    )
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
