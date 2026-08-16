defmodule Hancho.InstructionPack do
  @moduledoc "A versioned, attributed prompt fragment that cannot grant workflow authority."

  @enforce_keys [:name, :version, :source, :fragment]
  defstruct [
    :name,
    :version,
    :source,
    :fragment,
    required_capabilities: [],
    expected_artifacts: [],
    optional: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          source: String.t(),
          fragment: String.t(),
          required_capabilities: [String.t()],
          expected_artifacts: [String.t()],
          optional: boolean()
        }

  @spec hash(t()) :: String.t()
  def hash(pack) do
    :crypto.hash(:sha256, pack.fragment) |> Base.encode16(case: :lower)
  end
end
