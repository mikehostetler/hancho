defmodule Hancho.Command.Result do
  @moduledoc """
  The completed result of an operating-system command.
  """

  @enforce_keys [:stdout, :stderr, :exit_status]
  defstruct [:stdout, :stderr, :exit_status]

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_status: non_neg_integer()
        }
end
