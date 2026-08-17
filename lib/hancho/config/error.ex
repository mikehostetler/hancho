defmodule Hancho.Config.Error do
  @moduledoc """
  An error found while Hancho reads or validates configuration.
  """

  defexception [:kind, :path, :message, details: []]

  @type kind :: :read | :decode | :validation
  @type t :: %__MODULE__{
          kind: kind(),
          path: String.t(),
          message: String.t(),
          details: term()
        }
end
