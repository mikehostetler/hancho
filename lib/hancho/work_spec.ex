defmodule Hancho.WorkSpec do
  @moduledoc "The admitted scope and verification contract for one Build.V1 work order."

  alias Hancho.{Error, JSON}

  @enforce_keys [:id, :title, :instructions, :allowed_scopes]
  defstruct [
    :id,
    :title,
    :instructions,
    :github_issue,
    :beadwork,
    :profile,
    allowed_scopes: [],
    checks: [],
    acceptance_conditions: [],
    required_gates: []
  ]

  @type t :: %__MODULE__{}

  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(work_ref, options \\ []) do
    cond do
      spec = Keyword.get(options, :work_spec) ->
        from_map(spec, work_ref)

      path = Keyword.get(options, :spec_path) ->
        from_file(path, work_ref)

      scopes = Keyword.get(options, :allowed_scopes) ->
        from_map(
          %{
            "id" => work_ref,
            "title" => Keyword.get(options, :title, work_ref),
            "instructions" =>
              Keyword.get(options, :instructions, "Implement the admitted work order."),
            "allowed_scopes" => scopes,
            "checks" => Keyword.get(options, :checks, []),
            "profile" => Keyword.get(options, :profile, "elixir_library"),
            "acceptance_conditions" => Keyword.get(options, :acceptance_conditions, [])
          },
          work_ref
        )

      true ->
        {:error,
         %Error{
           code: :work_spec_required,
           exit_status: 64,
           message: "Build.V1 needs an admitted work specification. Use '--spec FILE'."
         }}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(spec), do: Map.from_struct(spec)

  defp from_file(path, work_ref) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- decode(content, path) do
      from_map(data, work_ref)
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         %Error{
           code: :work_spec_read_failed,
           exit_status: 66,
           message: "Cannot read work specification '#{path}': #{:file.format_error(reason)}"
         }}
    end
  end

  defp decode(content, path) do
    {:ok, JSON.decode!(content)}
  rescue
    _ ->
      {:error,
       %Error{
         code: :invalid_work_spec,
         exit_status: 65,
         message: "Work specification '#{path}' is not valid JSON."
       }}
  end

  defp from_map(data, work_ref) when is_map(data) do
    spec = %__MODULE__{
      id: data["id"] || data[:id] || work_ref,
      title: data["title"] || data[:title],
      instructions: data["instructions"] || data[:instructions],
      allowed_scopes: data["allowed_scopes"] || data[:allowed_scopes] || [],
      checks: data["checks"] || data[:checks] || [],
      profile: data["profile"] || data[:profile] || "elixir_library",
      acceptance_conditions: data["acceptance_conditions"] || data[:acceptance_conditions] || [],
      required_gates: data["required_gates"] || data[:required_gates] || [],
      github_issue: data["github_issue"] || data[:github_issue],
      beadwork: data["beadwork"] || data[:beadwork]
    }

    case validate(spec, work_ref) do
      [] ->
        {:ok, spec}

      errors ->
        {:error,
         %Error{
           code: :invalid_work_spec,
           exit_status: 65,
           message: "Work specification is invalid: #{Enum.join(errors, "; ")}",
           details: %{errors: errors}
         }}
    end
  end

  defp validate(spec, work_ref) do
    []
    |> require(spec.id == work_ref, "id must match work reference '#{work_ref}'")
    |> require(is_binary(spec.title) and spec.title != "", "title is required")
    |> require(
      is_binary(spec.instructions) and spec.instructions != "",
      "instructions are required"
    )
    |> require(
      is_list(spec.allowed_scopes) and spec.allowed_scopes != [],
      "allowed_scopes must not be empty"
    )
    |> require(
      Enum.all?(spec.allowed_scopes, &valid_scope?/1),
      "allowed_scopes contains an unsafe path"
    )
    |> require(valid_checks?(spec.checks), "checks must be lists of command arguments")
  end

  defp valid_scope?(scope) when is_binary(scope) and scope != "" do
    Path.type(scope) == :relative and
      not Enum.any?(Path.split(scope), &(&1 in ["..", ".git", ".hancho"]))
  end

  defp valid_scope?(_scope), do: false

  defp valid_checks?(checks) when is_list(checks) do
    Enum.all?(checks, fn command ->
      is_list(command) and command != [] and Enum.all?(command, &is_binary/1)
    end)
  end

  defp valid_checks?(_checks), do: false

  defp require(errors, true, _message), do: errors
  defp require(errors, false, message), do: [message | errors]
end
