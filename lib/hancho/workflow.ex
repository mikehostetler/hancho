defmodule Hancho.Workflow do
  @moduledoc false

  alias Hancho.Workflow.Definition

  @callback definition() :: Definition.t()
end
