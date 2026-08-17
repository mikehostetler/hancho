defmodule Hancho.State.Cluster do
  @moduledoc false

  use Bedrock.Cluster,
    otp_app: :hancho,
    name: "hancho"
end
