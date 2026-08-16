defmodule Hancho.Workflow.Transition do
  @moduledoc false
  @enforce_keys [:from, :event, :to]
  defstruct [:from, :event, :to, actions: [], guards: []]

  @type guard_rule ::
          {:fact, String.t()}
          | {:artifact, String.t()}
          | {:decision, String.t()}
          | {:authority, String.t()}
  @type t :: %__MODULE__{
          from: String.t(),
          event: String.t(),
          to: String.t(),
          actions: [map()],
          guards: [guard_rule()]
        }
end
