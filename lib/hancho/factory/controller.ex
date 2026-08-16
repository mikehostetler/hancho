defmodule Hancho.Factory.Controller do
  @moduledoc "Owns one durable queue and supervises work for one local factory."

  use GenServer

  alias Hancho.Factory.{Client, Store, Work}

  alias Hancho.{
    Config,
    Doctor,
    Error,
    ID,
    JSON,
    Journal,
    ReadModel,
    Repository
  }

  @type state :: :operating | :paused | :stopping | :unhealthy

  @spec start_link(Repository.t(), keyword()) :: GenServer.on_start()
  def start_link(repository, options \\ []) do
    DynamicSupervisor.start_child(Hancho.FactorySupervisor, %{
      id: {__MODULE__, repository.id || repository.root},
      start: {__MODULE__, :start_controller, [repository, options]},
      restart: :temporary,
      shutdown: 15_000,
      type: :worker
    })
  end

  @doc false
  def start_controller(repository, options),
    do: GenServer.start_link(__MODULE__, {repository, options})

  @spec stop(pid(), boolean()) :: :ok
  def stop(controller, force \\ false), do: GenServer.cast(controller, {:stop, force})

  @impl true
  def init({repository, options}) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- Config.load(repository),
         :ok <- required_doctor_checks(repository),
         {:ok, lock} <- acquire_lock(repository),
         {:ok, listener} <- listen(repository),
         :ok <- recover_interrupted(repository),
         {:ok, uncertain_actions} <- Journal.uncertain_actions(repository),
         {:ok, uncertain_effects} <- Journal.uncertain_effects(repository) do
      factory_id = ID.generate("factory")

      state =
        if uncertain_actions == [] and uncertain_effects == [], do: :operating, else: :unhealthy

      controller = self()
      acceptor = spawn(fn -> accept_loop(listener, controller) end)

      data = %{
        repository: repository,
        config: config,
        factory_id: factory_id,
        host: Keyword.get(options, :host, "foreground"),
        state: state,
        health: if(state == :operating, do: "healthy", else: "reconciliation_required"),
        started_at: Hancho.Clock.utc_now(),
        lock: lock,
        listener: listener,
        acceptor: acceptor,
        active: %{},
        subscriber: Keyword.get(options, :subscriber),
        interrupt_count: 0
      }

      :ok =
        Store.event(
          repository,
          factory_id,
          "started",
          nil,
          Atom.to_string(state),
          actor(),
          data.health
        )

      :ok = write_metadata(data)
      schedule_tick(data)
      notify(data, "factory #{factory_id} #{state}")
      {:ok, data}
    else
      {:error, %Error{} = error} -> {:stop, error}
      {:error, reason} -> {:stop, startup_error(reason)}
    end
  end

  @impl true
  def handle_call({:control, request}, _from, data) do
    if request["factory_id"] != data.factory_id do
      {:reply, error_response(:factory_identity_mismatch, "Factory identity does not match.", 77),
       data}
    else
      handle_command(request["command"], request["arguments"] || %{}, data)
    end
  end

  @impl true
  def handle_cast({:stop, force}, data) do
    {_reply, next} = stop_command(force, data)
    {:noreply, next}
  end

  @impl true
  def handle_info(:tick, data) do
    data = release_ready_work(data)
    schedule_tick(data)
    {:noreply, data}
  end

  def handle_info({reference, result}, data) when is_reference(reference) do
    case Map.pop(data.active, reference) do
      {nil, _active} ->
        {:noreply, data}

      {%{task: task, queue_id: queue_id}, active} ->
        Process.demonitor(task.ref, [:flush])
        finish_queue(data.repository, queue_id, result)
        next = %{data | active: active}
        notify(next, queue_event(queue_id, result))
        :ok = write_metadata(next)
        maybe_stop(next)
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, data) do
    case Map.pop(data.active, reference) do
      {nil, _active} ->
        {:noreply, data}

      {%{queue_id: queue_id}, active} ->
        error = %{code: "worker_exit", message: inspect(reason)}
        :ok = Store.finish(data.repository, queue_id, "failed", nil, error)
        next = %{data | active: active}
        notify(next, "queue #{queue_id} failed: #{inspect(reason)}")
        :ok = write_metadata(next)
        maybe_stop(next)
    end
  end

  def handle_info(:stop_now, data), do: {:stop, :normal, data}

  def handle_info({:EXIT, _pid, _reason}, data), do: {:noreply, data}
  def handle_info(_message, data), do: {:noreply, data}

  @impl true
  def terminate(reason, data) do
    if Map.has_key?(data, :listener), do: :gen_tcp.close(data.listener)
    if Map.has_key?(data, :acceptor), do: Process.exit(data.acceptor, :kill)

    if Map.has_key?(data, :repository) do
      remove_exact(Client.socket_path(data.repository))
      release_lock(data)

      stopped = %{
        factory_id: data.factory_id,
        repository_id: data.repository.id,
        host: data.host,
        pid: System.pid(),
        started_at: data.started_at,
        stopped_at: Hancho.Clock.utc_now(),
        config_hash: data.config.hash,
        state: "stopped",
        health:
          if(reason in [:normal, :shutdown] and data.state == :stopping,
            do: "stopped",
            else: "abnormal_stop"
          )
      }

      write_json(Client.metadata_path(data.repository), stopped)
    end

    :ok
  end

  defp handle_command("ping", _arguments, data) do
    {:reply, ok_response(%{factory_id: data.factory_id, state: data.state}), data}
  end

  defp handle_command("status", _arguments, data) do
    {:reply, ok_response(status(data)), data}
  end

  defp handle_command("queue", _arguments, data) do
    {:ok, items} = Store.list(data.repository)
    {:reply, ok_response(%{items: items}), data}
  end

  defp handle_command("submit", arguments, data) do
    cond do
      data.state in [:stopping, :unhealthy] ->
        {:reply,
         error_response(
           :factory_not_accepting_work,
           "The factory is #{data.state} and cannot accept new work.",
           75
         ), data}

      not is_binary(arguments["workflow"]) or not is_binary(arguments["work_ref"]) ->
        {:reply, error_response(:invalid_submission, "workflow and work_ref are required.", 64),
         data}

      true ->
        case Store.submit(
               data.repository,
               arguments["workflow"],
               arguments["work_ref"],
               arguments["options"] || %{}
             ) do
          {:ok, item} ->
            notify(data, "queue #{item["id"]} accepted")
            {:reply, ok_response(%{accepted: true, item: item}), data}

          {:error, error} ->
            {:reply, error_response(:queue_write_failed, Exception.message(error), 74), data}
        end
    end
  end

  defp handle_command("pause", _arguments, data) do
    case data.state do
      :operating ->
        next = change_state(data, :paused, "paused", "Operator paused release")
        {:reply, ok_response(status(next)), next}

      :paused ->
        {:reply, ok_response(status(data)), data}

      _ ->
        {:reply, error_response(:factory_state_conflict, "The factory is #{data.state}.", 75),
         data}
    end
  end

  defp handle_command("continue", _arguments, data) do
    case data.state do
      :paused ->
        next = change_state(data, :operating, "continued", "Operator continued release")
        {:reply, ok_response(status(next)), next}

      :operating ->
        {:reply, ok_response(status(data)), data}

      _ ->
        {:reply,
         error_response(
           :factory_state_conflict,
           "The factory is #{data.state}. Reconcile it before release.",
           75
         ), data}
    end
  end

  defp handle_command("down", arguments, data) do
    {reply, next} = stop_command(arguments["force"] == true, data)
    {:reply, reply, next}
  end

  defp handle_command(command, _arguments, data) do
    {:reply,
     error_response(:unknown_factory_command, "Unknown factory command '#{command}'.", 64), data}
  end

  defp stop_command(force, data) do
    cond do
      data.state == :stopping and not force ->
        {ok_response(status(data)), data}

      force ->
        Enum.each(data.active, fn {_reference, %{task: task, queue_id: queue_id}} ->
          :ok = Store.finish(data.repository, queue_id, "failed", nil, %{code: "forced_stop"})
          Task.shutdown(task, :brutal_kill)
        end)

        next =
          change_state(
            %{data | active: %{}},
            :stopping,
            "forced_stop",
            "Operator forced termination"
          )

        Process.send_after(self(), :stop_now, 500)
        {ok_response(status(next)), next}

      true ->
        next = change_state(data, :stopping, "stop_requested", "Operator requested a safe stop")
        if map_size(next.active) == 0, do: Process.send_after(self(), :stop_now, 500)
        {ok_response(status(next)), next}
    end
  end

  defp release_ready_work(%{state: :operating} = data) do
    available = max(wip_limit(data) - map_size(data.active), 0)

    if available == 0 do
      data
    else
      case Store.ready(data.repository, available) do
        {:ok, items} ->
          Enum.reduce(items, data, &start_item/2)

        {:error, _error} ->
          change_state(data, :unhealthy, "queue_read_failed", "Cannot read queue")
      end
    end
  end

  defp release_ready_work(data), do: data

  defp start_item(item, data) do
    case Store.claim(data.repository, item["id"], data.factory_id) do
      {:ok, claimed} ->
        task =
          Task.Supervisor.async_nolink(Hancho.TaskSupervisor, fn ->
            Work.run(data.repository, claimed)
          end)

        active = Map.put(data.active, task.ref, %{task: task, queue_id: item["id"]})
        next = %{data | active: active}
        notify(next, "queue #{item["id"]} released")
        :ok = write_metadata(next)
        next

      {:error, _reason} ->
        data
    end
  end

  defp finish_queue(repository, queue_id, {:ok, %{work_order: work_order}}) do
    status = if work_order["status"] == "complete", do: "complete", else: "stopped"
    Store.finish(repository, queue_id, status, work_order["id"])
  end

  defp finish_queue(repository, queue_id, {:error, %Error{} = error}) do
    Store.finish(repository, queue_id, "failed", nil, %{
      code: to_string(error.code),
      message: error.message
    })
  end

  defp finish_queue(repository, queue_id, result) do
    Store.finish(repository, queue_id, "failed", nil, %{message: inspect(result)})
  end

  defp queue_event(queue_id, {:ok, %{work_order: work_order}}),
    do: "queue #{queue_id} #{work_order["status"]} run=#{work_order["id"]}"

  defp queue_event(queue_id, _result), do: "queue #{queue_id} failed"

  defp maybe_stop(%{state: :stopping, active: active} = data) when map_size(active) == 0 do
    Process.send_after(self(), :stop_now, 500)
    {:noreply, data}
  end

  defp maybe_stop(data), do: {:noreply, data}

  defp status(data) do
    {:ok, queue} = Store.list(data.repository)
    {:ok, decisions} = Journal.open_decisions(data.repository)
    {:ok, effects} = Journal.uncertain_effects(data.repository)
    {:ok, actions} = Journal.uncertain_actions(data.repository)
    {:ok, andon} = ReadModel.andon_stops(data.repository)
    ready = Enum.filter(queue, &(&1["status"] == "ready"))
    blocked = Enum.filter(queue, &(&1["status"] in ["stopped", "failed"]))

    %{
      factory_id: data.factory_id,
      repository_id: data.repository.id,
      host: data.host,
      pid: System.pid(),
      state: data.state,
      health: data.health,
      started_at: data.started_at,
      config_hash: data.config.hash,
      workflows:
        Hancho.Workflow.Registry.list()
        |> Enum.map(&%{name: &1.name, version: &1.version}),
      harnesses: Hancho.Harness.Router.list(data.config),
      wip: %{limit: wip_limit(data), active: map_size(data.active)},
      ready_work: ready,
      active_work: active_items(data, queue),
      blocks: blocked,
      decisions: decisions,
      andon: andon ++ if(data.state == :unhealthy, do: [%{reason: data.health}], else: []),
      uncertain_effects: effects,
      uncertain_actions: actions,
      next_command: next_command(data, decisions, effects, actions)
    }
  end

  defp active_items(data, queue) do
    ids = Map.values(data.active) |> Enum.map(& &1.queue_id) |> MapSet.new()
    Enum.filter(queue, &MapSet.member?(ids, &1["id"]))
  end

  defp next_command(%{state: :unhealthy}, _decisions, effects, actions) do
    case List.first(effects) || List.first(actions) do
      nil -> "hancho down"
      item -> "hancho reconcile #{item["run_id"]}"
    end
  end

  defp next_command(%{state: :paused}, _decisions, _effects, _actions), do: "hancho continue"
  defp next_command(%{state: :stopping}, _decisions, _effects, _actions), do: "hancho status"

  defp next_command(_data, [decision | _], _effects, _actions),
    do: "hancho approve #{decision["id"]} --reason TEXT"

  defp next_command(_data, _decisions, _effects, _actions),
    do: "hancho run WORKFLOW WORK_REF --detach"

  defp wip_limit(data), do: data.config.data["wip_limit"] || 1

  defp change_state(data, result_state, event, reason) do
    if data.state == result_state do
      data
    else
      :ok =
        Store.event(
          data.repository,
          data.factory_id,
          event,
          Atom.to_string(data.state),
          Atom.to_string(result_state),
          actor(),
          reason
        )

      health = if result_state == :unhealthy, do: reason, else: "healthy"
      next = %{data | state: result_state, health: health}
      :ok = write_metadata(next)
      notify(next, "factory #{result_state}: #{reason}")
      next
    end
  end

  defp schedule_tick(data) do
    interval = get_in(data.config.data, ["factory", "poll_interval_ms"]) || 500
    Process.send_after(self(), :tick, interval)
  end

  defp required_doctor_checks(repository) do
    doctor = Doctor.run(repository)

    if doctor.result == "ok" do
      :ok
    else
      failures =
        doctor.checks
        |> Enum.filter(&(&1.required and &1.status == "fail"))
        |> Enum.map_join("; ", &"#{&1.name}: #{&1.detail}")

      {:error,
       %Error{
         code: :doctor_failed,
         exit_status: 69,
         message: "Factory startup failed required doctor checks: #{failures}"
       }}
    end
  end

  defp recover_interrupted(repository) do
    with :ok <- Store.recover_active(repository),
         :ok <- Journal.mark_incomplete_actions_uncertain(repository),
         :ok <- Journal.mark_incomplete_effects_uncertain(repository) do
      :ok
    end
  end

  defp acquire_lock(repository) do
    path = lock_path(repository)
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        IO.write(file, JSON.encode!(%{pid: System.pid(), started_at: Hancho.Clock.utc_now()}))
        :ok = File.chmod(path, 0o600)
        {:ok, %{file: file, path: path}}

      {:error, :eexist} ->
        if stale_lock?(path) do
          remove_exact(path)
          acquire_lock(repository)
        else
          {:error,
           %Error{
             code: :factory_already_active,
             exit_status: 73,
             message: "Another controller owns '#{repository.runtime_dir}'."
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_lock?(path) do
    with {:ok, content} <- File.read(path),
         %{"pid" => pid} <- JSON.decode!(content),
         {pid, ""} <- Integer.parse(to_string(pid)) do
      case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_output, 0} -> false
        _ -> true
      end
    else
      _ -> true
    end
  rescue
    _ -> true
  end

  defp listen(repository) do
    path = Client.socket_path(repository)
    remove_exact(path)

    case :gen_tcp.listen(0, [
           :binary,
           active: false,
           packet: :line,
           reuseaddr: true,
           ifaddr: {:local, String.to_charlist(path)}
         ]) do
      {:ok, listener} ->
        :ok = File.chmod(path, 0o600)
        {:ok, listener}

      error ->
        error
    end
  end

  defp accept_loop(listener, controller) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker = spawn(fn -> receive do: ({:serve, accepted} -> serve(accepted, controller)) end)
        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:serve, socket})
        accept_loop(listener, controller)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(50)
        accept_loop(listener, controller)
    end
  end

  defp serve(socket, controller) do
    response =
      with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
           request when is_map(request) <- JSON.decode!(line) do
        GenServer.call(controller, {:control, request}, 30_000)
      else
        _ -> error_response(:invalid_control_request, "The control request is invalid.", 64)
      end

    :gen_tcp.send(socket, JSON.encode!(response) <> "\n")
    :gen_tcp.close(socket)
  rescue
    _ -> :gen_tcp.close(socket)
  end

  defp write_metadata(data) do
    write_json(Client.metadata_path(data.repository), %{
      factory_id: data.factory_id,
      repository_id: data.repository.id,
      host: data.host,
      pid: System.pid(),
      started_at: data.started_at,
      config_hash: data.config.hash,
      state: data.state,
      health: data.health,
      wip_active: map_size(data.active),
      wip_limit: wip_limit(data)
    })
  end

  defp write_json(path, data) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, JSON.encode!(data), [:exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    end
  end

  defp release_lock(%{lock: %{file: file, path: path}}) do
    File.close(file)
    remove_exact(path)
  end

  defp release_lock(_data), do: :ok

  defp lock_path(repository), do: Path.join(repository.runtime_dir, "locks/factory.lock")

  defp remove_exact(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp notify(%{subscriber: subscriber}, message) when is_pid(subscriber),
    do: send(subscriber, {:factory_event, message})

  defp notify(_data, _message), do: :ok

  defp ok_response(data), do: %{ok: true, data: data}

  defp error_response(code, message, status) do
    %{ok: false, error: %{code: code, message: message, exit_status: status}}
  end

  defp startup_error(reason) do
    %Error{
      code: :factory_start_failed,
      exit_status: 73,
      message: "Cannot start the local factory: #{inspect(reason)}"
    }
  end

  defp actor, do: System.get_env("USER") || "local-user"
end
