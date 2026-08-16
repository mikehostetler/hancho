defmodule Hancho.Workflow.Station do
  @moduledoc false
  @enforce_keys [:id, :capability]
  defstruct [:id, :capability, authority: "standard", evidence: []]

  @type t :: %__MODULE__{
          id: String.t(),
          capability: String.t(),
          authority: String.t(),
          evidence: [String.t()]
        }
end
