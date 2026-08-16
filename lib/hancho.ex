defmodule Hancho do
  @moduledoc """
  Coordinates durable software-factory workflows in one Git repository.
  """

  @version Mix.Project.config()[:version]

  @spec version() :: String.t()
  def version, do: @version
end
