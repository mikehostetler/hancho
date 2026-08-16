defmodule Hancho.Workflow.Rejection do
  @moduledoc false
  defstruct [:code, :message, :state, :event, missing: []]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          state: String.t(),
          event: String.t(),
          missing: [term()]
        }
end
