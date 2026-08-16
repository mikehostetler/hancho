defmodule Hancho.Delivery.Result do
  @moduledoc false

  @enforce_keys [:status]
  defstruct [:status, :external_id, :message, evidence: %{}]

  @type status :: String.t()
  @type t :: %__MODULE__{
          status: status(),
          external_id: String.t() | nil,
          message: String.t() | nil,
          evidence: map()
        }
end
