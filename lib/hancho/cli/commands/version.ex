defmodule Hancho.CLI.Commands.Version do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result

  @impl true
  def execute([], _options) do
    version = Hancho.version()
    %Result{data: %{result: "ok", version: version}, text: version}
  end
end
