defmodule Hancho.Workflow.OnError do
  @moduledoc "A bounded coding-agent repair policy for one workflow gate."

  @repairable_codes %{
    "Hancho.Actions.ValidateScope" => ["changes_outside_allowed_scope"],
    "Hancho.Actions.Verify" => ["verification_failed"]
  }

  @schema Zoi.struct(
            __MODULE__,
            %{
              codes: Zoi.array(Zoi.string() |> Zoi.min(1)) |> Zoi.min(1) |> Zoi.max(8),
              repair_with: Zoi.string() |> Zoi.min(1),
              max_attempts: Zoi.integer() |> Zoi.min(1) |> Zoi.max(3),
              retry_step: Zoi.string() |> Zoi.min(1),
              timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(600_000),
              idle_timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(300_000),
              andon_warning_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(120_000),
              progress_interval_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(30_000)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attributes), do: Zoi.parse(@schema, attributes)

  @spec validate(String.t(), String.t(), t() | nil) :: :ok | {:error, String.t()}
  def validate(_action, _step_name, nil), do: :ok

  def validate(action, step_name, %__MODULE__{} = policy) do
    allowed = Map.get(@repairable_codes, action, [])
    unsupported = policy.codes -- allowed

    cond do
      allowed == [] ->
        {:error, "Step '#{step_name}' does not support an on_error repair policy."}

      policy.retry_step != step_name ->
        {:error, "Step '#{step_name}' can retry only itself after a repair."}

      unsupported != [] ->
        {:error,
         "Step '#{step_name}' has unsupported repair codes: #{Enum.join(unsupported, ", ")}."}

      true ->
        :ok
    end
  end
end
