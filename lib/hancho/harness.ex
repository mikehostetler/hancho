defmodule Hancho.Harness do
  @moduledoc false

  def ensure_started do
    with :ok <- Hancho.ProcessManager.ensure_started(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      :ok
    end
  end

  def run(provider, prompt, options \\ []) do
    with :ok <- ensure_started() do
      Jido.Harness.run(provider, prompt, options)
    end
  end
end
