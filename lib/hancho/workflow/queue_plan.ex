defmodule Hancho.Workflow.QueuePlan do
  @moduledoc "Builds deterministic child run identities for a selected task list."

  alias Hancho.Beadwork.Issue

  defmodule Item do
    @moduledoc false
    @schema Zoi.struct(
              __MODULE__,
              %{
                position: Zoi.integer() |> Zoi.min(0),
                issue_id: Zoi.string() |> Zoi.min(1),
                run_id: Zoi.string() |> Zoi.min(1)
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

    @spec new!(map()) :: t()
    def new!(attributes), do: Zoi.parse!(@schema, attributes)
  end

  @spec build(String.t(), [Issue.t()]) :: [Item.t()]
  def build(queue_id, issues) do
    issues
    |> Enum.with_index()
    |> Enum.map(fn {issue, position} ->
      Item.new!(%{
        position: position,
        issue_id: issue.id,
        run_id:
          "#{queue_id}-#{(position + 1) |> Integer.to_string() |> String.pad_leading(3, "0")}"
      })
    end)
  end

  @spec from_state(map()) :: [Item.t()]
  def from_state(queue) do
    Enum.map(queue["items"], fn item ->
      Item.new!(%{
        position: item["position"],
        issue_id: item["issue_id"],
        run_id: item["run_id"]
      })
    end)
  end
end
