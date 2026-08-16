defmodule Hancho.Error do
  @moduledoc "A typed error that the command-line interface can show without a stack trace."

  defexception [:message, :code, :details, exit_status: 1]

  @type t :: %__MODULE__{
          message: String.t(),
          code: atom() | String.t(),
          details: map() | nil,
          exit_status: non_neg_integer()
        }
end
