defmodule Hancho.Clock do
  @moduledoc false

  @spec utc_now() :: String.t()
  def utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
