defmodule Hancho.Harness.Protocol do
  @moduledoc "Harness protocol version 1 validation and JSON conversion."

  alias Hancho.Harness.{Request, Result}
  alias Hancho.{Error, JSON}

  @required_request_fields ~w(run_id workflow workflow_version station repository_path worktree_path prompt_path capability authority paths)
  @known_request_fields @required_request_fields ++ ~w(protocol_version model limits)
  @known_statuses ~w(success failure timeout cancelled output_limit)

  @spec encode_request(Request.t()) :: String.t()
  def encode_request(%Request{} = request) do
    request |> Map.from_struct() |> JSON.encode!()
  end

  @spec decode_request(String.t()) :: {:ok, Request.t()} | {:error, Error.t()}
  def decode_request(json) do
    with {:ok, data} <- decode_json(json),
         :ok <- validate_request_map(data) do
      {:ok,
       struct!(Request, %{
         run_id: data["run_id"],
         workflow: data["workflow"],
         workflow_version: data["workflow_version"],
         station: data["station"],
         repository_path: data["repository_path"],
         worktree_path: data["worktree_path"],
         prompt_path: data["prompt_path"],
         capability: data["capability"],
         authority: data["authority"],
         paths: data["paths"],
         protocol_version: data["protocol_version"],
         model: data["model"],
         limits: data["limits"] || %{}
       })}
    end
  end

  @spec parse_output(String.t(), map()) :: {:ok, Result.t()} | {:error, Error.t()}
  def parse_output(output, identity) do
    decoded =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
        case decode_json(line) do
          {:ok, row} when is_map(row) ->
            {:cont, {:ok, [row | rows]}}

          _ ->
            {:halt,
             protocol_error(:malformed_output, "Adapter output contains invalid JSON Lines data.")}
        end
      end)

    with {:ok, rows} <- decoded do
      rows = Enum.reverse(rows)
      final = Enum.find(Enum.reverse(rows), &(&1["type"] == "result"))
      events = Enum.filter(rows, &(&1["type"] == "event"))

      cond do
        is_nil(final) ->
          protocol_error(:missing_result, "Adapter output has no final result record.")

        final["status"] not in @known_statuses ->
          protocol_error(
            :invalid_result,
            "Adapter result status '#{final["status"]}' is not valid."
          )

        true ->
          {:ok,
           %Result{
             status: final["status"],
             adapter: identity.adapter,
             harness: identity.harness,
             adapter_version: identity[:adapter_version],
             harness_version: identity[:harness_version],
             session_id: final["session_id"],
             exit_status: final["exit_status"],
             stdout_path: identity[:stdout_path],
             stderr_path: identity[:stderr_path],
             events: events,
             details: final["details"] || %{}
           }}
      end
    end
  end

  defp validate_request_map(data) when is_map(data) do
    missing = Enum.reject(@required_request_fields, &Map.has_key?(data, &1))
    unknown = Map.keys(data) -- @known_request_fields

    cond do
      data["protocol_version"] != 1 ->
        protocol_error(:unsupported_protocol, "Harness protocol version must be 1.")

      missing != [] ->
        protocol_error(
          :missing_request_fields,
          "Harness request is missing: #{Enum.join(missing, ", ")}."
        )

      unknown != [] ->
        protocol_error(
          :unknown_request_fields,
          "Harness request has unknown required fields: #{Enum.join(unknown, ", ")}."
        )

      true ->
        :ok
    end
  end

  defp decode_json(json) do
    {:ok, JSON.decode!(json)}
  rescue
    _ -> protocol_error(:invalid_json, "Harness protocol data is not valid JSON.")
  end

  defp protocol_error(code, message) do
    {:error, %Error{code: code, exit_status: 65, message: message}}
  end
end
