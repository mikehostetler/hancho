defmodule Hancho.Config.Schema do
  @moduledoc false

  @capability Zoi.enum(~w(read edit_worktree review))

  @harness Zoi.map(
             %{
               "adapter" => Zoi.string() |> Zoi.min(1),
               "command" => Zoi.string() |> Zoi.min(1),
               "capabilities" => Zoi.array(@capability)
             },
             unrecognized_keys: :preserve
           )

  @schema Zoi.map(
            %{
              "schema_version" => Zoi.literal(1),
              "wip_limit" => Zoi.integer() |> Zoi.positive(),
              "default_harness" => Zoi.string() |> Zoi.min(1),
              "harnesses" => Zoi.map(Zoi.string(), @harness),
              "routes" => Zoi.map(Zoi.string(), Zoi.map(Zoi.string(), Zoi.string()))
            },
            unrecognized_keys: :preserve
          )

  @spec errors(term()) :: [String.t()]
  def errors(config) do
    case Zoi.parse(@schema, config) do
      {:ok, _config} -> []
      {:error, errors} -> Enum.map(errors, &format_error/1)
    end
  end

  defp format_error(error) do
    path = Enum.map_join(error.path, ".", &to_string/1)
    if path == "", do: error.message, else: "#{path} #{error.message}"
  end
end
