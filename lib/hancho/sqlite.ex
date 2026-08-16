defmodule Hancho.SQLite do
  @moduledoc false

  alias Hancho.{Error, JSON}

  @spec execute(Path.t(), String.t()) :: :ok | {:error, Error.t()}
  def execute(path, sql) do
    File.mkdir_p!(Path.dirname(path))

    case System.cmd(executable(), ["-batch", "-bail", "-cmd", ".timeout 5000", path, sql],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, sqlite_error(path, status, output)}
    end
  rescue
    error in ErlangError ->
      {:error,
       %Error{
         code: :sqlite_unavailable,
         exit_status: 69,
         message: "Cannot start sqlite3: #{Exception.message(error)}. Run 'hancho doctor'."
       }}
  end

  @spec query(Path.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def query(path, sql) do
    case System.cmd(
           executable(),
           ["-batch", "-bail", "-json", "-cmd", ".timeout 5000", path, sql],
           stderr_to_stdout: true
         ) do
      {"", 0} -> {:ok, []}
      {output, 0} -> {:ok, JSON.decode!(output)}
      {output, status} -> {:error, sqlite_error(path, status, output)}
    end
  rescue
    error in ErlangError ->
      {:error,
       %Error{
         code: :sqlite_unavailable,
         exit_status: 69,
         message: "Cannot start sqlite3: #{Exception.message(error)}. Run 'hancho doctor'."
       }}
  end

  @spec scalar(Path.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def scalar(path, sql) do
    with {:ok, rows} <- query(path, sql) do
      case rows do
        [row | _] when map_size(row) > 0 -> {:ok, row |> Map.values() |> hd()}
        _ -> {:ok, nil}
      end
    end
  end

  @spec quote(term()) :: String.t()
  def quote(nil), do: "NULL"
  def quote(true), do: "1"
  def quote(false), do: "0"
  def quote(value) when is_integer(value) or is_float(value), do: to_string(value)
  def quote(value) when is_atom(value), do: __MODULE__.quote(Atom.to_string(value))
  def quote(value) when is_binary(value), do: "'#{String.replace(value, "'", "''")}'"

  @spec executable() :: String.t()
  def executable, do: System.get_env("HANCHO_SQLITE3") || "sqlite3"

  defp sqlite_error(path, status, output) do
    %Error{
      code: :sqlite_error,
      exit_status: 74,
      message: "SQLite failed for '#{path}' with status #{status}: #{String.trim(output)}"
    }
  end
end
