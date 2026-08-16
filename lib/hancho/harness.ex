defmodule Hancho.Harness do
  @moduledoc false

  @helper_name "exec-port"

  def ensure_started do
    with :ok <- configure_erlexec(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      :ok
    end
  end

  def run(provider, prompt, options \\ []) do
    with :ok <- ensure_started() do
      Jido.Harness.run(provider, prompt, options)
    end
  end

  defp configure_erlexec do
    if Process.whereis(:exec) do
      :ok
    else
      with {:ok, path} <- erlexec_helper_path() do
        Application.put_env(:erlexec, :portexe, String.to_charlist(path))
      end
    end
  end

  defp erlexec_helper_path do
    case installed_helper_path() do
      nil -> extract_helper()
      path -> {:ok, path}
    end
  end

  defp installed_helper_path do
    case :code.priv_dir(:erlexec) do
      path when is_list(path) ->
        path
        |> List.to_string()
        |> Path.join("*/#{@helper_name}")
        |> Path.wildcard()
        |> Enum.find(&File.regular?/1)

      _error ->
        nil
    end
  end

  defp extract_helper do
    with script when is_list(script) <- :escript.script_name(),
         {:ok, sections} <- :escript.extract(script, []),
         {:archive, archive} when is_binary(archive) <- List.keyfind(sections, :archive, 0),
         {:ok, entries} <- :zip.list_dir(archive),
         {:ok, name} <- helper_entry(entries),
         {:ok, [{^name, contents}]} <- :zip.extract(archive, [:memory, {:file_list, [name]}]) do
      cache_helper(contents)
    else
      error -> {:error, {:erlexec_helper_unavailable, error}}
    end
  end

  defp helper_entry(entries) do
    names =
      entries
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(fn name ->
        is_list(name) and String.starts_with?(List.to_string(name), "erlexec/priv/") and
          String.ends_with?(List.to_string(name), "/#{@helper_name}")
      end)

    case names do
      [name] -> {:ok, name}
      _names -> {:error, :erlexec_helper_not_unique}
    end
  end

  defp cache_helper(contents) do
    digest = contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    directory = Path.join([cache_root(), "native", digest])
    path = Path.join(directory, @helper_name)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- write_helper(path, contents),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    end
  end

  defp write_helper(path, contents) do
    case File.read(path) do
      {:ok, ^contents} -> :ok
      _result -> File.write(path, contents, [:binary])
    end
  end

  defp cache_root do
    case :filename.basedir(:user_cache, "hancho") do
      path when is_binary(path) -> path
      path when is_list(path) -> List.to_string(path)
    end
  end
end
