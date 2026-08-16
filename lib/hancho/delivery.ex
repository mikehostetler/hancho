defmodule Hancho.Delivery do
  @moduledoc "Runs opt-in delivery adapters with durable effect intent and observation."

  alias Hancho.Delivery.{Hex, Phoenix, Request, Result}
  alias Hancho.{Clock, Config, Error, ID, Journal, JSON, Repository, SQLite, Store}

  @statuses ~w(requested started confirmed uncertain contained reversed)

  @spec run(Repository.t(), Request.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(repository, %Request{} = request, options \\ []) do
    dry_run = Keyword.get(options, :dry_run, true)

    with :ok <- validate(request),
         {:ok, config} <- Config.load(repository),
         {:ok, adapter} <- adapter(request.adapter),
         {:ok, row} <- record_request(repository, request),
         context <- context(repository, config),
         {:ok, result} <-
           if(dry_run,
             do: adapter.dry_run(request, context),
             else: execute(repository, row, request, adapter, context, options)
           ),
         {:ok, row} <- finish_request(repository, row["id"], result) do
      {:ok, %{request: row, result: result, dry_run: dry_run}}
    end
  end

  @spec list(Repository.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(repository, run_id) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM delivery_requests WHERE run_id = #{q(run_id)} ORDER BY requested_at, id;"
    )
  end

  defp execute(repository, row, request, adapter, context, options) do
    if Keyword.get(options, :opt_in, false) != true do
      {:error,
       error(
         :delivery_opt_in_required,
         "External delivery needs explicit opt-in. Use a dry-run first."
       )}
    else
      target =
        JSON.encode!(%{
          adapter: request.adapter,
          artifact: request.artifact,
          environment: request.target_environment
        })

      with {:ok, effect} <-
             Journal.effect_intent(
               repository,
               request.run_id,
               "delivery_#{request.adapter}",
               target,
               "delivery:#{request.adapter}:#{request.run_id}:#{request.artifact}:#{request.target_environment}"
             ),
           {:ok, effect} <- Journal.prepare_effect_retry(repository, effect),
           :ok <- effect_runnable(effect),
           :ok <- start_request(repository, row["id"], effect["id"]) do
        case adapter.execute(request, context) do
          {:ok, %Result{status: status} = result}
          when status in ~w(confirmed uncertain contained reversed) ->
            with {:ok, _effect} <-
                   Journal.observe_effect(
                     repository,
                     effect["id"],
                     result.status,
                     Map.from_struct(result)
                   ) do
              {:ok, result}
            end

          {:ok, _result} ->
            mark_delivery_uncertain(
              repository,
              effect,
              "Delivery adapter returned an invalid state."
            )

          {:error, failure} ->
            mark_delivery_uncertain(repository, effect, Exception.message(failure))
        end
      end
    end
  end

  defp mark_delivery_uncertain(repository, effect, message) do
    with {:ok, _effect} <-
           Journal.observe_effect(repository, effect["id"], "uncertain", %{error: message}) do
      {:error,
       error(
         :delivery_uncertain,
         "Delivery result is uncertain. Use the recorded recovery method before retry."
       )}
    end
  end

  defp validate(%Request{} = request) do
    errors =
      []
      |> required(request.artifact, "artifact")
      |> required(request.target_environment, "target environment")
      |> required(request.authority, "authority")
      |> required(request.recovery_method, "recovery method")
      |> checks(request.checks)
      |> secret_names(request.secret_env)

    if errors == [],
      do: :ok,
      else: {:error, error(:invalid_delivery_request, Enum.join(Enum.reverse(errors), "; "))}
  end

  defp required(errors, value, _label) when is_binary(value) and value != "", do: errors
  defp required(errors, _value, label), do: ["#{label} is required" | errors]
  defp checks(errors, value) when is_list(value) and value != [], do: errors
  defp checks(errors, _value), do: ["at least one delivery check is required" | errors]

  defp secret_names(errors, names) when is_list(names) do
    if Enum.all?(names, &(is_binary(&1) and Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, &1))),
      do: errors,
      else: ["secret_env can contain only environment-variable names" | errors]
  end

  defp secret_names(errors, _names), do: ["secret_env must be a list" | errors]

  defp record_request(repository, request) do
    id = ID.generate("delivery")
    now = Clock.utc_now()

    request_map =
      request
      |> Map.from_struct()
      |> Map.drop([:secret_env])
      |> Map.put(:secret_env, request.secret_env)

    sql = """
    INSERT INTO delivery_requests
      (id, run_id, adapter, artifact, target_environment, authority, checks_json, recovery_method,
       secret_env_json, request_json, status, requested_at)
    VALUES
      (#{q(id)}, #{q(request.run_id)}, #{q(request.adapter)}, #{q(request.artifact)},
       #{q(request.target_environment)}, #{q(request.authority)}, #{q(JSON.encode!(request.checks))},
       #{q(request.recovery_method)}, #{q(JSON.encode!(request.secret_env))}, #{q(JSON.encode!(request_map))},
       'requested', #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql), do: get(repository, id)
  end

  defp start_request(repository, id, effect_id) do
    SQLite.execute(
      Store.path(repository),
      "UPDATE delivery_requests SET status = 'started', effect_id = #{q(effect_id)}, started_at = #{q(Clock.utc_now())} WHERE id = #{q(id)} AND status = 'requested';"
    )
  end

  defp finish_request(repository, id, %Result{status: status} = result)
       when status in @statuses do
    with :ok <-
           SQLite.execute(
             Store.path(repository),
             "UPDATE delivery_requests SET status = #{q(status)}, result_json = #{q(JSON.encode!(Map.from_struct(result)))}, finished_at = #{q(Clock.utc_now())} WHERE id = #{q(id)};"
           ),
         do: get(repository, id)
  end

  defp get(repository, id) do
    with {:ok, [row]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM delivery_requests WHERE id = #{q(id)} LIMIT 1;"
           ),
         do: {:ok, row}
  end

  defp effect_runnable(%{"status" => "intent"}), do: :ok

  defp effect_runnable(effect),
    do:
      {:error,
       error(
         :delivery_reconciliation_required,
         "Delivery effect '#{effect["id"]}' is '#{effect["status"]}'. Reconcile before retry."
       )}

  defp adapter("hex"), do: {:ok, Hex}
  defp adapter("phoenix"), do: {:ok, Phoenix}

  defp adapter(name),
    do: {:error, error(:unknown_delivery_adapter, "Unknown delivery adapter '#{name}'.")}

  defp context(repository, config) do
    %{
      repository: repository,
      timeout_ms: get_in(config.data, ["limits", "harness_timeout_ms"]) || 900_000,
      max_output_bytes: get_in(config.data, ["limits", "max_output_bytes"]) || 10_485_760
    }
  end

  defp q(value), do: SQLite.quote(value)
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
