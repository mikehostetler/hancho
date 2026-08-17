defmodule Hancho.Log.Filter do
  @moduledoc false

  def select(event, include_internal?) do
    domain = get_in(event, [:meta, :domain]) || []

    if factory_domain?(domain) or (include_internal? and hancho_domain?(domain)) do
      event
    else
      :ignore
    end
  end

  def suppress_selected(event, include_internal?) do
    domain = get_in(event, [:meta, :domain]) || []

    if factory_domain?(domain) or (include_internal? and hancho_domain?(domain)) do
      :stop
    else
      :ignore
    end
  end

  # Elixir Logger adds :elixir to a caller-supplied domain. Accept both the
  # Elixir form and the native OTP Logger form so that one handler can capture
  # activity from both APIs.
  defp factory_domain?([:elixir | domain]), do: factory_domain?(domain)
  defp factory_domain?([:hancho, :factory | _rest]), do: true
  defp factory_domain?(_domain), do: false

  defp hancho_domain?([:elixir | domain]), do: hancho_domain?(domain)
  defp hancho_domain?([:hancho | _rest]), do: true
  defp hancho_domain?(_domain), do: false
end
