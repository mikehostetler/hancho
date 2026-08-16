defmodule Hancho.Workflow.Registry do
  @moduledoc false

  alias Hancho.Error
  alias Hancho.Workflow.Definition

  @modules [
    Hancho.Workflows.WalkingSkeleton.V1,
    Hancho.Workflows.Build.V1,
    Hancho.Workflows.Plan.V1,
    Hancho.Workflows.Audit.V1
  ]

  @spec list() :: [Definition.t()]
  def list, do: Enum.map(@modules, & &1.definition())

  @spec fetch(String.t(), pos_integer() | :latest) :: {:ok, Definition.t()} | {:error, Error.t()}
  def fetch(name, version \\ :latest) do
    matches = Enum.filter(list(), &(&1.name == name))

    definition =
      case version do
        :latest -> Enum.max_by(matches, & &1.version, fn -> nil end)
        number -> Enum.find(matches, &(&1.version == number))
      end

    if definition do
      {:ok, definition}
    else
      {:error,
       %Error{
         code: :unknown_workflow,
         exit_status: 64,
         message: "Workflow '#{name}' version '#{version}' is not installed."
       }}
    end
  end

  @spec validate_all() :: :ok | {:error, [String.t()]}
  def validate_all do
    errors =
      Enum.flat_map(list(), fn definition ->
        Enum.map(
          Definition.validate(definition),
          &"#{definition.name}.v#{definition.version}: #{&1}"
        )
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end
