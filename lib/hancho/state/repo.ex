defmodule Hancho.State.Repo do
  @moduledoc false

  use Bedrock.Repo, cluster: Hancho.State.Cluster
end
