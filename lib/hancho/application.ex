defmodule Hancho.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Hancho.TaskSupervisor},
      {DynamicSupervisor, name: Hancho.FactorySupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hancho.Supervisor)
  end
end
