defmodule Hancho.Actions.Context do
  @moduledoc false

  def service(context, name, default) do
    context |> Map.get(:services, %{}) |> Map.get(name, default)
  end
end
