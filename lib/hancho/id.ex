defmodule Hancho.ID do
  @moduledoc false

  @spec generate(String.t()) :: String.t()
  def generate(prefix) do
    random =
      :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false) |> String.downcase()

    "#{prefix}-#{random}"
  end
end
