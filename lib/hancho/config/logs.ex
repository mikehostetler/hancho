defmodule Hancho.Config.Logs do
  @moduledoc """
  Options for repository-local factory activity logs.
  """

  @enforce_keys [
    :enabled,
    :path,
    :format,
    :console,
    :include_internal,
    :sync_interval_ms,
    :max_bytes,
    :max_files,
    :compress
  ]
  defstruct [
    :enabled,
    :path,
    :format,
    :console,
    :include_internal,
    :sync_interval_ms,
    :max_bytes,
    :max_files,
    :compress
  ]

  @type format :: :jsonl | :text
  @type t :: %__MODULE__{
          enabled: boolean(),
          path: String.t(),
          format: format(),
          console: boolean(),
          include_internal: boolean(),
          sync_interval_ms: non_neg_integer(),
          max_bytes: pos_integer(),
          max_files: non_neg_integer(),
          compress: boolean()
        }
end
