defmodule Hancho.Harness.Request do
  @moduledoc false

  @enforce_keys [
    :run_id,
    :workflow,
    :workflow_version,
    :station,
    :repository_path,
    :worktree_path,
    :prompt_path,
    :capability,
    :authority,
    :paths
  ]
  defstruct [
    :run_id,
    :workflow,
    :workflow_version,
    :station,
    :repository_path,
    :worktree_path,
    :prompt_path,
    :capability,
    :authority,
    :model,
    :paths,
    protocol_version: 1,
    limits: %{}
  ]

  @type t :: %__MODULE__{}
end
