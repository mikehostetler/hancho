defmodule Hancho.OSProcess.Manager do
  @moduledoc false

  @cache_directory "hancho/native"
  @helper_name "exec-port"

  def child_spec(_options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker
    }
  end

  def start_link(_options) do
    with {:ok, helper_path} <- helper_path() do
      options =
        [{:portexe, String.to_charlist(helper_path)}]
        |> maybe_add_shell()

      case :exec.start_link(options) do
        {:error, {:already_started, pid}} ->
          Process.link(pid)
          {:ok, pid}

        result ->
          result
      end
    end
  end

  defp helper_path do
    case installed_helper_path() do
      nil -> extract_escript_helper()
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

  defp extract_escript_helper do
    with script_name when is_list(script_name) <- :escript.script_name(),
         {:ok, sections} <- :escript.extract(script_name, []),
         {:archive, archive} when is_binary(archive) <- List.keyfind(sections, :archive, 0),
         {:ok, entries} <- :zip.list_dir(archive),
         {:ok, entry_name} <- helper_entry(entries),
         {:ok, [{^entry_name, contents}]} <-
           :zip.extract(archive, [:memory, {:file_list, [entry_name]}]) do
      cache_helper(contents)
    else
      error -> {:error, {:cannot_extract_erlexec_helper, error}}
    end
  end

  defp helper_entry(entries) do
    matches =
      entries
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(fn name ->
        is_list(name) and
          String.starts_with?(List.to_string(name), "erlexec/priv/") and
          String.ends_with?(List.to_string(name), "/#{@helper_name}")
      end)

    case matches do
      [entry_name] -> {:ok, entry_name}
      _matches -> {:error, :erlexec_helper_entry_not_unique}
    end
  end

  defp cache_helper(contents) do
    digest = contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    directory = Path.join([cache_root(), @cache_directory, digest])
    helper_path = Path.join(directory, @helper_name)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- ensure_cached_helper(helper_path, contents, digest),
         :ok <- File.chmod(helper_path, 0o700) do
      {:ok, helper_path}
    end
  end

  defp ensure_cached_helper(path, contents, digest) do
    if valid_cached_helper?(path, digest) do
      :ok
    else
      temporary_path = path <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.write(temporary_path, contents, [:binary, :exclusive]),
           :ok <- File.chmod(temporary_path, 0o700),
           :ok <- install_cached_helper(temporary_path, path),
           true <- valid_cached_helper?(path, digest) do
        :ok
      else
        false -> {:error, :cached_erlexec_helper_is_not_valid}
        error -> error
      end
    end
  end

  defp install_cached_helper(temporary_path, path) do
    case File.rename(temporary_path, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        File.rm(temporary_path)
        :ok

      error ->
        File.rm(temporary_path)
        error
    end
  end

  defp valid_cached_helper?(path, digest) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> Kernel.==(digest)

      _error ->
        false
    end
  end

  defp cache_root do
    System.get_env("HANCHO_NATIVE_CACHE") ||
      System.get_env("XDG_CACHE_HOME") ||
      Path.join(System.user_home!(), ".cache")
  end

  defp maybe_add_shell(options) do
    if System.get_env("SHELL") in [nil, ""] do
      [{:env, [{~c"SHELL", ~c"/bin/sh"}]} | options]
    else
      options
    end
  end
end
