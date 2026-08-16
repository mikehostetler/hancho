defmodule Hancho.Delivery.Request do
  @moduledoc "Names one delivery artifact, target, authority, checks, recovery method, and secret environment names."

  @enforce_keys [
    :run_id,
    :adapter,
    :artifact,
    :target_environment,
    :authority,
    :checks,
    :recovery_method
  ]
  defstruct [
    :run_id,
    :adapter,
    :artifact,
    :target_environment,
    :authority,
    :checks,
    :recovery_method,
    secret_env: [],
    options: %{}
  ]

  @type t :: %__MODULE__{}
end
