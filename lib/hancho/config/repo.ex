defmodule Hancho.Config.Repo do
  @moduledoc """
  Repository values in the Hancho configuration.
  """

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}
end
