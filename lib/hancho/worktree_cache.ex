defmodule Hancho.WorktreeCache do
  @moduledoc "Provides repository-local Mix cache paths shared by serial worktrees."

  @spec environment(String.t()) :: %{String.t() => String.t()}
  def environment(workspace) do
    repository = repository_from_workspace(workspace)
    deps = Path.join(repository, "deps")
    build = Path.join(repository, "_build")

    with :ok <- File.mkdir_p(deps),
         :ok <- File.mkdir_p(build) do
      %{"MIX_DEPS_PATH" => deps, "MIX_BUILD_PATH" => build}
    else
      {:error, _reason} -> %{}
    end
  end

  defp repository_from_workspace(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.find_index(parts, &(&1 == ".hancho")) do
      nil -> Path.expand(path)
      index -> parts |> Enum.take(index) |> Path.join()
    end
  end
end
