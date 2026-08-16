defmodule Hancho.CLI.Result do
  @moduledoc false
  defstruct [:data, :text, status: 0]

  @type t :: %__MODULE__{data: term(), text: String.t(), status: non_neg_integer()}
end
