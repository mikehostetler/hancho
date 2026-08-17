defmodule Hancho.Native do
  @moduledoc false

  @nif_prefix "exqlite/priv/sqlite3_nif."
  @app_path "exqlite/ebin/exqlite.app"

  @spec ensure_exqlite(String.t()) :: :ok | {:error, term()}
  def ensure_exqlite(hancho_dir) do
    if exqlite_nif_available?() do
      :ok
    else
      install_exqlite(:escript.script_name(), hancho_dir)
    end
  end

  @doc false
  @spec install_exqlite(charlist(), String.t()) :: :ok | {:error, term()}
  def install_exqlite(escript_path, hancho_dir) do
    with {:ok, entries} <- :escript.extract(escript_path, []),
         {:ok, files} <- entries |> Keyword.fetch!(:archive) |> :zip.extract([:memory]),
         {:ok, nif_name, nif} <- find_file(files, @nif_prefix),
         {:ok, _app_name, app} <- find_file(files, @app_path),
         :ok <- write_native_files(hancho_dir, nif_name, nif, app) do
      activate_exqlite(hancho_dir)
    else
      {:error, reason} -> {:error, {:native_runtime, reason}}
    end
  rescue
    error -> {:error, {:native_runtime, Exception.message(error)}}
  end

  defp exqlite_nif_available? do
    case :code.priv_dir(:exqlite) do
      path when is_list(path) -> Path.wildcard(Path.join(to_string(path), "sqlite3_nif.*")) != []
      _other -> false
    end
  end

  defp find_file(files, path) do
    Enum.find_value(files, {:error, "Missing packaged file: #{path}"}, fn {name, contents} ->
      name = to_string(name)

      if name == path or String.starts_with?(name, path) do
        {:ok, name, contents}
      end
    end)
  end

  defp write_native_files(hancho_dir, nif_name, nif, app) do
    root = Path.join([hancho_dir, "native", "exqlite"])
    priv = Path.join(root, "priv")
    ebin = Path.join(root, "ebin")

    with :ok <- File.mkdir_p(priv),
         :ok <- File.mkdir_p(ebin),
         :ok <- File.write(Path.join(priv, Path.basename(nif_name)), nif, [:binary]),
         :ok <- File.write(Path.join(ebin, "exqlite.app"), app, [:binary]),
         :ok <- File.chmod(Path.join(hancho_dir, "native"), 0o700),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.chmod(priv, 0o700),
         :ok <- File.chmod(ebin, 0o700) do
      :ok
    end
  end

  defp activate_exqlite(hancho_dir) do
    ebin = Path.join([hancho_dir, "native", "exqlite", "ebin"])

    case :code.add_patha(String.to_charlist(ebin)) do
      true -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
