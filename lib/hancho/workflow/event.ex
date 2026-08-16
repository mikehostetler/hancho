defmodule Hancho.Workflow.Event do
  @moduledoc false
  @enforce_keys [:name]
  defstruct [:name, :expected_state, :reason, :actor, :correlation_id, payload: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          expected_state: String.t() | nil,
          reason: String.t() | nil,
          actor: String.t() | nil,
          correlation_id: String.t() | nil,
          payload: map()
        }
end
