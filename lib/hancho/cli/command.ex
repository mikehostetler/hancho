defmodule Hancho.CLI.Command do
  @moduledoc false

  alias Hancho.CLI.Result

  @callback execute([String.t()], keyword()) :: Result.t()
end
