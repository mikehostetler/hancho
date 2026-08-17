defmodule Hancho.Workflow.Default do
  @moduledoc false

  @implementation_path Path.expand("../../../priv/workflows/implement.yaml", __DIR__)
  @implementation_prompt_path Path.expand("../../../priv/prompts/implement.md", __DIR__)
  @external_resource @implementation_path
  @external_resource @implementation_prompt_path
  @implementation File.read!(@implementation_path)
  @implementation_prompt File.read!(@implementation_prompt_path)

  @spec install(Hancho.Project.t()) :: :ok | {:error, term()}
  def install(project) do
    prompts_path = Path.join(project.hancho_dir, "prompts")

    with :ok <- File.mkdir_p(project.workflows_path),
         :ok <- File.mkdir_p(prompts_path),
         :ok <- write_new(Path.join(project.workflows_path, "implement.yaml"), @implementation),
         :ok <- write_new(Path.join(prompts_path, "implement.md"), @implementation_prompt) do
      :ok
    end
  end

  @spec implementation() :: String.t()
  def implementation, do: @implementation

  @spec implementation_prompt() :: String.t()
  def implementation_prompt, do: @implementation_prompt

  defp write_new(path, contents) do
    if File.exists?(path), do: :ok, else: File.write(path, contents)
  end
end
