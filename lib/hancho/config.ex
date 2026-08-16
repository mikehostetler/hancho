defmodule Hancho.Config do
  @moduledoc "Loads and validates repository-local Hancho configuration."

  alias Hancho.{Error, JSON, Repository, TOML}

  @known_capabilities ~w(read edit_worktree review)
  @known_workflows ~w(walking_skeleton build plan audit)
  @station_capabilities %{
    "walking_skeleton" => %{"operate" => "read"},
    "build" => %{
      "implement" => "edit_worktree",
      "repair" => "edit_worktree",
      "review" => "review"
    },
    "plan" => %{"research" => "read", "draft" => "read", "review" => "review"},
    "audit" => %{"inventory" => "read", "inspect" => "read", "validate" => "review"}
  }

  @spec default_toml() :: String.t()
  def default_toml do
    """
    schema_version = 1
    default_harness = "fake"
    wip_limit = 1

    [factory]
    background_host = "tmux"
    poll_interval_ms = 500
    auto_pull = false

    [audit]
    wip_limit = 2
    evidence_budget_bytes = 65536

    [redaction]
    patterns = ["(?i)(password|token|secret)[=:][^ ]+"]

    [retention]
    raw_logs_days = 7
    prompts_days = 30
    checks_days = 30
    reports_days = 365
    temp_worktrees_days = 7

    [review]
    require_independent_harness = false

    [harnesses.fake]
    adapter = "builtin:fake"
    command = "fake"
    capabilities = ["read", "edit_worktree", "review"]

    [routes.walking_skeleton]
    operate = "fake"

    [routes.build]
    implement = "fake"
    repair = "fake"
    review = "fake"

    [routes.plan]
    research = "fake"
    draft = "fake"
    review = "fake"

    [routes.audit]
    inventory = "fake"
    inspect = "fake"
    validate = "fake"

    [limits]
    harness_timeout_ms = 900000
    max_fix_attempts = 2
    max_output_bytes = 10485760
    """
  end

  @spec load(Repository.t()) :: {:ok, map()} | {:error, Error.t()}
  def load(repository) do
    path = Repository.config_path(repository)

    with {:ok, text} <- read(path),
         {:ok, config} <- TOML.parse(text),
         :ok <- validate(config) do
      {:ok,
       %{
         data: config,
         hash: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
         path: path,
         sources: source_map(config, path)
       }}
    end
  end

  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(config) do
    errors =
      []
      |> validate_schema(config)
      |> validate_wip(config)
      |> validate_harnesses(config)
      |> validate_routes(config)
      |> validate_redaction(config)
      |> validate_secrets(config)

    case Enum.reverse(errors) do
      [] ->
        :ok

      errors ->
        {:error,
         %Error{
           code: :invalid_config,
           exit_status: 78,
           message: "Configuration is invalid: #{Enum.join(errors, "; ")}",
           details: %{errors: errors}
         }}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error,
         %Error{
           code: :config_read_failed,
           exit_status: 66,
           message: "Cannot read '#{path}': #{:file.format_error(reason)}. Run 'hancho init'."
         }}
    end
  end

  defp validate_schema(errors, %{"schema_version" => 1}), do: errors

  defp validate_schema(errors, %{"schema_version" => version}),
    do: ["unsupported schema_version #{inspect(version)}" | errors]

  defp validate_schema(errors, _config), do: ["schema_version must be 1" | errors]

  defp validate_wip(errors, %{"wip_limit" => value}) when is_integer(value) and value > 0,
    do: errors

  defp validate_wip(errors, _config), do: ["wip_limit must be a positive integer" | errors]

  defp validate_harnesses(errors, config) do
    harnesses = Map.get(config, "harnesses", %{})
    default = Map.get(config, "default_harness")

    errors =
      if is_map(harnesses) and map_size(harnesses) > 0 do
        errors
      else
        ["at least one harness is required" | errors]
      end

    errors =
      if Map.has_key?(harnesses, default),
        do: errors,
        else: ["default_harness is unknown" | errors]

    Enum.reduce(harnesses, errors, fn {name, harness}, acc ->
      acc
      |> require_string(harness, "harnesses.#{name}.adapter")
      |> require_string(harness, "harnesses.#{name}.command")
      |> validate_capabilities(harness, name)
    end)
  end

  defp require_string(errors, map, path) do
    key = path |> String.split(".") |> List.last()

    if is_binary(Map.get(map, key)) and Map.get(map, key) != "",
      do: errors,
      else: ["#{path} must be a non-empty string" | errors]
  end

  defp validate_capabilities(errors, harness, name) do
    capabilities = Map.get(harness, "capabilities", [])

    unknown =
      if is_list(capabilities),
        do: Enum.reject(capabilities, &(&1 in @known_capabilities)),
        else: []

    cond do
      not is_list(capabilities) ->
        ["harnesses.#{name}.capabilities must be a list" | errors]

      unknown != [] ->
        ["harnesses.#{name} has unknown capabilities #{Enum.join(unknown, ",")}" | errors]

      true ->
        errors
    end
  end

  defp validate_routes(errors, config) do
    routes = Map.get(config, "routes", %{})
    harnesses = Map.get(config, "harnesses", %{})

    errors =
      routes
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_workflows))
      |> Enum.reduce(errors, fn workflow, acc -> ["unknown workflow route #{workflow}" | acc] end)

    Enum.reduce(routes, errors, fn {workflow, stations}, acc ->
      Enum.reduce(stations, acc, fn {station, harness}, nested ->
        required_capability = get_in(@station_capabilities, [workflow, station])
        harness_config = harnesses[harness]

        cond do
          is_nil(required_capability) ->
            ["routes.#{workflow}.#{station} is an unknown station route" | nested]

          is_nil(harness_config) ->
            ["routes.#{workflow}.#{station} uses unknown harness #{harness}" | nested]

          required_capability not in (harness_config["capabilities"] || []) ->
            [
              "routes.#{workflow}.#{station} requires capability #{required_capability} from harness #{harness}"
              | nested
            ]

          true ->
            nested
        end
      end)
    end)
  end

  defp validate_secrets(errors, config) do
    walk(config, [], errors, fn path, value, acc ->
      key = path |> List.last() |> to_string() |> String.downcase()

      if is_binary(value) and Regex.match?(~r/(password|secret|token|api[_-]?key)/, key) and
           not Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, value) do
        ["#{Enum.join(path, ".")} must name an environment variable, not contain a secret" | acc]
      else
        acc
      end
    end)
  end

  defp validate_redaction(errors, config) do
    patterns = get_in(config, ["redaction", "patterns"]) || []

    cond do
      not is_list(patterns) ->
        ["redaction.patterns must be a list" | errors]

      true ->
        Enum.reduce(patterns, errors, fn pattern, acc ->
          case Regex.compile(pattern) do
            {:ok, _regex} ->
              acc

            {:error, reason} ->
              ["redaction pattern #{inspect(pattern)} is invalid: #{inspect(reason)}" | acc]
          end
        end)
    end
  end

  defp walk(map, path, acc, fun) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, nested -> walk(value, path ++ [key], nested, fun) end)
  end

  defp walk(value, path, acc, fun), do: fun.(path, value, acc)

  defp source_map(config, path) do
    walk(config, [], %{}, fn key_path, _value, acc ->
      Map.put(acc, Enum.join(key_path, "."), path)
    end)
  end

  @spec safe_view(map()) :: map()
  def safe_view(%{data: data} = loaded) do
    %{
      config: redact(data),
      config_hash: loaded.hash,
      source: loaded.path,
      sources: loaded.sources
    }
  end

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if Regex.match?(~r/(password|secret|token|api[_-]?key)/i, key) do
        {key, "[ENV NAME REDACTED]"}
      else
        {key, redact(value)}
      end
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(value), do: value

  @spec encode_safe(map()) :: String.t()
  def encode_safe(loaded), do: loaded |> safe_view() |> JSON.encode!()
end
