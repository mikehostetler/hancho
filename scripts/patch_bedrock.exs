defmodule Hancho.Build.PatchBedrock do
  @moduledoc false

  @spec run(String.t()) :: :ok
  def run(bedrock_root) do
    path =
      Path.join([
        bedrock_root,
        "lib",
        "bedrock",
        "internal",
        "transaction_builder",
        "layout_index.ex"
      ])

    source = File.read!(path)

    unpatched = """
          |> Enum.flat_map(fn {start_key, end_key, _pids} -> [start_key, end_key] end)
          |> Enum.sort()
    """

    patched = unpatched <> "      |> Enum.dedup()\n"

    cond do
      String.contains?(source, patched) ->
        :ok

      length(:binary.matches(source, unpatched)) == 1 ->
        File.write!(path, String.replace(source, unpatched, patched))

      true ->
        raise "Bedrock layout-index source does not match the tested compatibility patch"
    end
  end
end
