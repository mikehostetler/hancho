defmodule Hancho.Factory.Client do
  @moduledoc "Sends authenticated commands to one repository-local factory controller."

  alias Hancho.{Error, JSON, Repository}

  @timeout 5_000

  @spec request(Repository.t(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(repository, command, arguments \\ %{}, timeout \\ @timeout) do
    with {:ok, factory_id} <- factory_id(repository),
         {:ok, socket} <- connect(repository, timeout),
         :ok <-
           :gen_tcp.send(
             socket,
             JSON.encode!(%{factory_id: factory_id, command: command, arguments: arguments}) <>
               "\n"
           ),
         {:ok, response} <- receive_response(socket, timeout) do
      :gen_tcp.close(socket)

      case response do
        %{"ok" => true, "data" => data} -> {:ok, data}
        %{"ok" => false, "error" => error} -> {:error, remote_error(error)}
        _ -> {:error, protocol_error("The factory returned an invalid response.")}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, connection_error(repository, reason)}
    end
  end

  @spec running?(Repository.t()) :: boolean()
  def running?(repository) do
    match?(
      {:ok, %{"state" => state}} when state in ["operating", "paused", "stopping", "unhealthy"],
      request(repository, "ping", %{}, 500)
    )
  end

  @spec socket_path(Repository.t()) :: Path.t()
  def socket_path(repository) do
    local = Path.join(repository.runtime_dir, "control.sock")

    if byte_size(local) <= 96 do
      local
    else
      suffix =
        :crypto.hash(:sha256, repository.runtime_dir)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 20)

      Path.join("/tmp", "hancho-#{suffix}.sock")
    end
  end

  @spec metadata_path(Repository.t()) :: Path.t()
  def metadata_path(repository), do: Path.join(repository.runtime_dir, "factory.json")

  defp factory_id(repository) do
    path = metadata_path(repository)

    with {:ok, content} <- File.read(path),
         %{"factory_id" => factory_id} when is_binary(factory_id) <- JSON.decode!(content) do
      {:ok, factory_id}
    else
      _ -> {:error, connection_error(repository, :no_metadata)}
    end
  rescue
    _ -> {:error, protocol_error("The local factory metadata is invalid.")}
  end

  defp connect(repository, timeout) do
    path = socket_path(repository) |> String.to_charlist()
    :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line], timeout)
  end

  defp receive_response(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, response} -> {:ok, JSON.decode!(response)}
      other -> other
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp remote_error(error) do
    %Error{
      code: error["code"] || :factory_command_failed,
      exit_status: error["exit_status"] || 75,
      message: error["message"] || "The factory command failed.",
      details: error["details"]
    }
  end

  defp connection_error(repository, reason) do
    %Error{
      code: :factory_not_active,
      exit_status: 69,
      message:
        "No active factory answered for '#{repository.root}' (#{inspect(reason)}). Run 'hancho up'."
    }
  end

  defp protocol_error(message) do
    %Error{code: :factory_protocol_error, exit_status: 76, message: message}
  end
end
