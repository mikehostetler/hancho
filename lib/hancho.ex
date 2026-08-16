defmodule Hancho do
  @moduledoc false

  @external_resource Path.expand("../mix.exs", __DIR__)
  @version Mix.Project.config() |> Keyword.fetch!(:version)

  def version, do: @version
end
