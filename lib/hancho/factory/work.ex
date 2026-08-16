defmodule Hancho.Factory.Work do
  @moduledoc false

  alias Hancho.{BuildRunner, Runner}

  def run(repository, item) do
    options = decode_options(item["options_json"])

    case item["workflow_name"] do
      "build" -> BuildRunner.run(repository, item["work_ref"], options)
      workflow -> Runner.run(repository, workflow, item["work_ref"], options)
    end
  end

  defp decode_options(json) do
    json
    |> Hancho.JSON.decode!()
    |> Enum.flat_map(fn
      {"spec_path", value} when is_binary(value) -> [spec_path: value]
      {"model", value} when is_binary(value) -> [model: value]
      {"approvals", value} when is_list(value) -> [approvals: value]
      _ -> []
    end)
  end
end
