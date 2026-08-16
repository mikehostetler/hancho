defmodule Hancho.Harness.Result do
  @moduledoc false

  @enforce_keys [:status, :adapter, :harness]
  defstruct [
    :status,
    :adapter,
    :harness,
    :adapter_version,
    :harness_version,
    :session_id,
    :exit_status,
    :stdout_path,
    :stderr_path,
    events: [],
    details: %{}
  ]

  @type t :: %__MODULE__{}
end
