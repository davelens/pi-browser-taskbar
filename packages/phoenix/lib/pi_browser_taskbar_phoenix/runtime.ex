defmodule PiBrowserTaskbarPhoenix.Runtime do
  @moduledoc """
  Owns one persistent Pi RPC process and serializes task admission for a host project.
  """

  use GenServer

  alias PiBrowserTaskbarPhoenix.Task, as: BrowserTask

  @max_record_bytes 1_000_000
  @max_output_bytes 32 * 1024
  @dialog_methods ~w(select confirm input editor)
  @default_abort_timeout 5_000
  @default_termination_timeout 1_000
  @default_restart_attempts 3
  @default_restart_delay 100
  @one_shot_system_prompt "You are handling a one-shot browser task with no reply channel. Complete the user's request autonomously without asking follow-up questions. Inspect the repository and use the supplied browser context. Resolve missing details with conservative assumptions. Act directly on implementation requests, but preserve explicit planning and read-only constraints. Do not repeat a failed approach unchanged. If safe completion is impossible, stop and report the exact blocker."

  defstruct [
    :name,
    :port,
    :port_pid,
    :executable,
    :project_root,
    :task_timeout,
    :abort_timeout,
    :termination_timeout,
    :max_restart_attempts,
    :restart_delay,
    :startup_id,
    :session_id,
    :pi_session_id,
    :model,
    :error,
    :task,
    :reset_command_id,
    :reset_state_id,
    :reset_from,
    reset_recovering: false,
    restart_attempts: 0,
    allowed_hosts: [],
    buffer: "",
    phase: :starting
  ]

  @type snapshot :: %{
          contract_version: 1,
          session: map(),
          task: map() | nil
        }

  @doc "Starts a project-scoped Pi runtime."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Returns the canonical current snapshot."
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Returns the startup-fixed access configuration."
  @spec config(GenServer.server()) :: %{allowed_hosts: [String.t()]}
  def config(server), do: GenServer.call(server, :config)

  @doc "Atomically admits one task or returns the current busy snapshot."
  @spec submit(GenServer.server(), BrowserTask.t()) ::
          {:ok, snapshot()} | {:error, :busy | :unavailable, snapshot()}
  def submit(server, %BrowserTask{} = task), do: GenServer.call(server, {:submit, task})

  @doc "Requests idempotent cancellation of the retained task."
  @spec cancel(GenServer.server(), String.t()) ::
          {:ok, :accepted | :cancelled, snapshot()}
          | {:error, :not_found | :not_cancellable | :unavailable, snapshot()}
  def cancel(server, task_id) when is_binary(task_id),
    do: GenServer.call(server, {:cancel, task_id})

  @doc "Starts and confirms a fresh Pi session while preserving rejected state."
  @spec reset(GenServer.server()) ::
          {:ok, snapshot()}
          | {:error, :reset_while_busy | :session_reset_rejected | :unavailable, snapshot()}
  def reset(server), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      executable: resolve_executable(Keyword.get(opts, :executable, "pi")),
      project_root: Keyword.fetch!(opts, :project_root),
      task_timeout: Keyword.get(opts, :task_timeout, 30 * 60_000),
      abort_timeout: Keyword.get(opts, :abort_timeout, @default_abort_timeout),
      termination_timeout: Keyword.get(opts, :termination_timeout, @default_termination_timeout),
      max_restart_attempts: Keyword.get(opts, :max_restart_attempts, @default_restart_attempts),
      restart_delay: Keyword.get(opts, :restart_delay, @default_restart_delay),
      allowed_hosts: Keyword.get(opts, :allowed_hosts, [])
    }

    send(self(), :start_port)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public_snapshot(state), state}

  def handle_call(:config, _from, state) do
    {:reply, %{allowed_hosts: state.allowed_hosts}, state}
  end

  def handle_call({:submit, _task}, _from, %{phase: :busy} = state) do
    {:reply, {:error, :busy, public_snapshot(state)}, state}
  end

  def handle_call({:submit, _task}, _from, %{phase: phase} = state) when phase != :ready do
    {:reply, {:error, :unavailable, public_snapshot(state)}, state}
  end

  def handle_call({:submit, task}, _from, state) do
    id = opaque_id()
    now = DateTime.utc_now()

    command_id = "task-#{id}"

    task_state = %{
      id: id,
      command_id: command_id,
      abort_command_id: nil,
      prompt: task.prompt,
      status: :running,
      output: "",
      output_truncated: false,
      activity: "Starting Pi",
      error: nil,
      prompt_accepted: false,
      pending_error: nil,
      started_at: now,
      finished_at: nil
    }

    command = %{type: "prompt", id: command_id, message: BrowserTask.to_prompt(task)}

    case send_command(state.port, command) do
      :ok ->
        Process.send_after(self(), {:task_timeout, id}, state.task_timeout)
        next = %{state | phase: :busy, task: task_state, error: nil}
        {:reply, {:ok, public_snapshot(next)}, next}

      {:error, :closed} ->
        next = begin_recovery(state, "Pi became unavailable before accepting the task")
        {:reply, {:error, :unavailable, public_snapshot(next)}, next}
    end
  end

  def handle_call({:cancel, _id}, _from, %{task: nil} = state),
    do: {:reply, {:error, :not_found, public_snapshot(state)}, state}

  def handle_call({:cancel, id}, _from, %{task: %{id: task_id}} = state) when id != task_id,
    do: {:reply, {:error, :not_found, public_snapshot(state)}, state}

  def handle_call({:cancel, _id}, _from, %{task: %{status: :cancelling}} = state),
    do: {:reply, {:ok, :accepted, public_snapshot(state)}, state}

  def handle_call({:cancel, _id}, _from, %{task: %{status: :cancelled}} = state),
    do: {:reply, {:ok, :cancelled, public_snapshot(state)}, state}

  def handle_call({:cancel, _id}, _from, %{task: %{status: status}} = state)
      when status in [:completed, :failed],
      do: {:reply, {:error, :not_cancellable, public_snapshot(state)}, state}

  def handle_call({:cancel, _id}, _from, %{task: %{status: :running}} = state) do
    abort_command_id = "abort-#{state.task.id}"

    case send_command(state.port, %{type: "abort", id: abort_command_id}) do
      :ok ->
        task = %{
          state.task
          | abort_command_id: abort_command_id,
            status: :cancelling,
            activity: "Stopping Pi"
        }

        Process.send_after(self(), {:abort_timeout, state.task.id}, state.abort_timeout)
        next = %{state | task: task}
        {:reply, {:ok, :accepted, public_snapshot(next)}, next}

      {:error, :closed} ->
        next =
          state
          |> fail_active_task("Pi stopped unexpectedly")
          |> begin_recovery("Pi became unavailable before accepting cancellation")

        {:reply, {:error, :unavailable, public_snapshot(next)}, next}
    end
  end

  def handle_call(:reset, _from, %{phase: phase} = state) when phase != :ready do
    {:reply, {:error, :reset_while_busy, public_snapshot(state)}, state}
  end

  def handle_call(:reset, from, state) do
    command_id = "reset-#{opaque_id()}"
    resetting = %{state | phase: :resetting, reset_command_id: command_id, reset_from: from}

    case send_command(state.port, %{type: "new_session", id: command_id}) do
      :ok -> {:noreply, resetting}
      {:error, :closed} -> {:noreply, recover_reset(resetting)}
    end
  end

  @impl true
  def handle_info(:start_port, %{executable: nil} = state) do
    next = unavailable(state, "Pi executable was not found")
    {:noreply, fail_reset(next)}
  end

  def handle_info(:start_port, state) do
    state = %{state | restart_attempts: state.restart_attempts + 1}

    case open_port(state) do
      {:ok, port} ->
        startup_id = "startup-#{opaque_id()}"
        port_pid = port_os_pid(port)

        case send_command(port, %{type: "get_state", id: startup_id}) do
          :ok ->
            {:noreply,
             %{
               state
               | port: port,
                 port_pid: port_pid,
                 startup_id: startup_id,
                 phase: :starting,
                 buffer: "",
                 error: nil
             }}

          {:error, :closed} ->
            terminate_port(port, state.termination_timeout, nil)
            {:noreply, retry_startup(state, "Pi stopped during startup")}
        end

      {:error, _reason} ->
        {:noreply, retry_startup(state, "Pi could not be started")}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume_data(state, data)}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port, phase: :resetting} = state) do
    {:noreply, recover_reset(%{state | port: nil})}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port, buffer: buffer} = state)
      when buffer != "" do
    {:noreply, restart_after_protocol_failure(state, "Pi sent an unterminated RPC record")}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port, phase: :starting} = state) do
    {:noreply, retry_startup(%{state | port: nil}, "Pi stopped during startup")}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    state = fail_active_task(state, "Pi stopped unexpectedly")
    {:noreply, begin_recovery(%{state | port: nil}, "Pi stopped unexpectedly")}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    handle_info({port, {:exit_status, 1}}, state)
  end

  def handle_info(
        {:task_timeout, id},
        %{phase: :busy, task: %{id: id, status: :running}} = state
      ) do
    state = fail_active_task(state, "Pi task exceeded the configured time limit")
    {:noreply, begin_recovery(state, "Pi is restarting")}
  end

  def handle_info(
        {:abort_timeout, id},
        %{phase: :busy, task: %{id: id, status: :cancelling}} = state
      ) do
    state = finish_task(state, :cancelled, "Pi did not stop before the cancellation deadline")
    {:noreply, begin_recovery(state, "Pi is restarting")}
  end

  def handle_info({:task_timeout, _id}, state), do: {:noreply, state}
  def handle_info({:abort_timeout, _id}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    terminate_port(state.port, state.termination_timeout, state.port_pid)
  end

  defp open_port(state) do
    {:ok,
     Port.open(
       {:spawn_executable, state.executable},
       [
         :binary,
         :exit_status,
         :use_stdio,
         args: ["--mode", "rpc", "--append-system-prompt", @one_shot_system_prompt],
         cd: state.project_root
       ]
     )}
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :open_failed}
  end

  defp consume_data(state, data) do
    {lines, remainder} = split_lines(state.buffer <> data)

    cond do
      Enum.any?(lines, &(byte_size(&1) + 1 > @max_record_bytes)) or
          byte_size(remainder) > @max_record_bytes ->
        restart_after_protocol_failure(state, "Pi sent an oversized RPC record")

      true ->
        consumed =
          Enum.reduce_while(lines, state, fn line, current ->
            next = consume_line(line, current)
            if next.port, do: {:cont, next}, else: {:halt, next}
          end)

        if consumed.port, do: %{consumed | buffer: remainder}, else: consumed
    end
  end

  defp split_lines(buffer) do
    parts = :binary.split(buffer, "\n", [:global])
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp consume_line(line, state) do
    line = trim_trailing_carriage_return(line)

    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        handle_event(state, event)

      {:ok, _event} ->
        restart_after_protocol_failure(state, "Pi sent a non-object RPC record")

      {:error, _reason} ->
        restart_after_protocol_failure(state, "Pi sent a malformed RPC record")
    end
  end

  defp trim_trailing_carriage_return(line) do
    if String.ends_with?(line, "\r"),
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  defp handle_event(state, %{
         "type" => "extension_ui_request",
         "id" => id,
         "method" => method
       })
       when method in @dialog_methods and is_binary(id) and id != "" do
    case send_command(state.port, %{type: "extension_ui_response", id: id, cancelled: true}) do
      :ok -> state
      {:error, :closed} -> restart_after_protocol_failure(state, "Pi protocol failed")
    end
  end

  defp handle_event(state, %{"type" => "extension_ui_request", "method" => method})
       when method in @dialog_methods do
    restart_after_protocol_failure(state, "Pi sent a malformed RPC event")
  end

  defp handle_event(state, %{
         "type" => "response",
         "id" => id,
         "success" => true,
         "data" => %{"sessionId" => pi_session_id} = data
       })
       when id == state.startup_id and is_binary(pi_session_id) and pi_session_id != "" do
    case model_name(data["model"]) do
      nil ->
        state
        |> unavailable("Pi returned invalid startup state")
        |> fail_reset()

      model ->
        ready = %{
          state
          | phase: :ready,
            session_id: opaque_id(),
            pi_session_id: pi_session_id,
            model: model,
            error: nil,
            restart_attempts: 0
        }

        if state.reset_from, do: complete_reset(ready), else: ready
    end
  end

  defp handle_event(state, %{"type" => "response", "id" => id, "success" => false})
       when id == state.startup_id do
    retry_startup(state, "Pi rejected its startup handshake")
  end

  defp handle_event(state, %{"type" => "response", "id" => id}) when id == state.startup_id do
    retry_startup(state, "Pi returned invalid startup state")
  end

  defp handle_event(%{phase: :starting} = state, %{"type" => "response"}) do
    retry_startup(state, "Pi returned an unexpected RPC response")
  end

  defp handle_event(%{phase: :resetting, reset_command_id: command_id} = state, %{
         "type" => "response",
         "id" => command_id,
         "success" => true,
         "data" => %{"cancelled" => true}
       }) do
    rejected = clear_reset(%{state | phase: :ready})

    GenServer.reply(
      state.reset_from,
      {:error, :session_reset_rejected, public_snapshot(rejected)}
    )

    rejected
  end

  defp handle_event(%{phase: :resetting, reset_command_id: command_id} = state, %{
         "type" => "response",
         "id" => command_id,
         "success" => true,
         "data" => %{"cancelled" => false}
       }) do
    state_id = "reset-state-#{opaque_id()}"

    case send_command(state.port, %{type: "get_state", id: state_id}) do
      :ok -> %{state | reset_state_id: state_id}
      {:error, :closed} -> recover_reset(state)
    end
  end

  defp handle_event(%{phase: :resetting, reset_command_id: command_id} = state, %{
         "type" => "response",
         "id" => command_id
       }) do
    recover_reset(state)
  end

  defp handle_event(%{phase: :resetting, reset_state_id: state_id} = state, %{
         "type" => "response",
         "id" => state_id,
         "success" => true,
         "data" => %{"sessionId" => pi_session_id} = data
       })
       when is_binary(pi_session_id) and pi_session_id != "" do
    model = model_name(data["model"])

    if pi_session_id == state.pi_session_id or is_nil(model) do
      recover_reset(state)
    else
      state
      |> Map.merge(%{
        phase: :ready,
        session_id: opaque_id(),
        pi_session_id: pi_session_id,
        model: model,
        error: nil
      })
      |> complete_reset()
    end
  end

  defp handle_event(%{phase: :resetting, reset_state_id: state_id} = state, %{
         "type" => "response",
         "id" => state_id
       }) do
    recover_reset(state)
  end

  defp handle_event(%{phase: :resetting} = state, %{"type" => "response"}) do
    recover_reset(state)
  end

  defp handle_event(
         %{phase: :busy, task: %{command_id: command_id, prompt_accepted: false}} = state,
         %{"type" => "response", "id" => command_id, "success" => true}
       ) do
    state
    |> put_in([Access.key(:task), Access.key(:prompt_accepted)], true)
    |> put_in([Access.key(:task), Access.key(:activity)], "Pi accepted the task")
  end

  defp handle_event(%{phase: :busy, task: %{command_id: command_id}} = state, %{
         "type" => "response",
         "id" => command_id,
         "success" => false
       }) do
    finish_task(state, :failed, "Pi rejected the task")
  end

  defp handle_event(%{phase: :busy, task: %{abort_command_id: command_id}} = state, %{
         "type" => "response",
         "id" => command_id,
         "success" => success
       })
       when not is_nil(command_id) and is_boolean(success) do
    if success,
      do: state,
      else: restart_after_protocol_failure(state, "Pi rejected cancellation")
  end

  defp handle_event(%{phase: :busy} = state, %{"type" => "response"}) do
    restart_after_protocol_failure(state, "Pi returned an unexpected RPC response")
  end

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "agent_start"
       }) do
    put_in(state.task.activity, "Pi is working")
  end

  defp handle_event(%{phase: :busy} = state, %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
       })
       when is_binary(delta) do
    {output, truncated?} = bounded_output(state.task.output <> delta)

    state
    |> put_in([Access.key(:task), Access.key(:output)], output)
    |> put_in(
      [Access.key(:task), Access.key(:output_truncated)],
      state.task.output_truncated or truncated?
    )
  end

  defp handle_event(%{phase: :busy} = state, %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "text_delta"}
       }) do
    restart_after_protocol_failure(state, "Pi sent a malformed RPC event")
  end

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "error"}
       }) do
    mark_pending_failure(state, "Pi reported a message error")
  end

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "agent_end"
       }) do
    put_in(state.task.activity, "Pi finished a turn")
  end

  defp handle_event(
         %{phase: :busy, task: %{status: :running}} = state,
         %{
           "type" => type
         } = event
       )
       when type in ["tool_execution_start", "tool_execution_update"] do
    put_in(state.task.activity, "Running #{safe_label(event["toolName"], "a tool")}")
  end

  defp handle_event(
         %{phase: :busy, task: %{status: :running}} = state,
         %{
           "type" => "tool_execution_end"
         } = event
       ) do
    prefix = if event["isError"] == true, do: "Tool failed", else: "Finished"
    put_in(state.task.activity, "#{prefix} #{safe_label(event["toolName"], "a tool")}")
  end

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "compaction_start"
       }) do
    put_in(state.task.activity, "Compacting conversation")
  end

  defp handle_event(
         %{phase: :busy, task: %{status: :running}} = state,
         %{
           "type" => "compaction_end"
         } = event
       ) do
    if is_binary(event["errorMessage"]) and event["errorMessage"] != "" do
      mark_pending_failure(state, "Pi could not compact the conversation")
    else
      activity =
        if event["willRetry"] == true,
          do: "Retrying after compaction",
          else: "Conversation compacted"

      put_in(state.task.activity, activity)
    end
  end

  defp handle_event(
         %{phase: :busy, task: %{status: :running}} = state,
         %{
           "type" => "auto_retry_start"
         } = event
       ) do
    activity =
      if is_integer(event["attempt"]) and event["attempt"] in 1..999 and
           is_integer(event["maxAttempts"]) and event["maxAttempts"] in 1..999,
         do: "Retrying request (#{event["attempt"]}/#{event["maxAttempts"]})",
         else: "Retrying request"

    put_in(state.task.activity, activity)
  end

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "auto_retry_end",
         "success" => false
       }) do
    mark_pending_failure(state, "Pi could not complete the task after retries")
  end

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "auto_retry_end",
         "success" => true
       }) do
    put_in(state.task.activity, "Pi is working")
  end

  defp handle_event(%{phase: :busy, task: %{status: :cancelling}} = state, %{
         "type" => "agent_settled"
       }) do
    finish_task(state, :cancelled, nil)
  end

  defp handle_event(%{phase: :busy, task: %{pending_error: error}} = state, %{
         "type" => "agent_settled"
       })
       when not is_nil(error) do
    finish_task(state, :failed, error)
  end

  defp handle_event(%{phase: :busy} = state, %{"type" => "agent_settled"}) do
    finish_task(state, :completed, nil)
  end

  defp handle_event(%{phase: :ready} = state, %{"type" => "response"}) do
    restart_after_protocol_failure(state, "Pi returned an unexpected RPC response")
  end

  defp handle_event(state, _event), do: state

  defp mark_pending_failure(state, message) do
    state
    |> put_in([Access.key(:task), Access.key(:pending_error)], message)
    |> put_in([Access.key(:task), Access.key(:activity)], "Task failed")
  end

  defp finish_task(state, status, error) do
    activity =
      Map.get(%{completed: "Task completed", cancelled: "Task stopped"}, status, "Task failed")

    task = %{
      state.task
      | status: status,
        activity: activity,
        error: error,
        finished_at: DateTime.utc_now()
    }

    %{state | phase: :ready, task: task}
  end

  defp fail_active_task(%{phase: :busy, task: task} = state, message) when not is_nil(task),
    do: finish_task(state, :failed, message)

  defp fail_active_task(state, _message), do: state

  defp restart_after_protocol_failure(%{phase: :resetting} = state, _message),
    do: recover_reset(state)

  defp restart_after_protocol_failure(%{phase: :starting} = state, _message) do
    retry_startup(state, "Pi protocol failed")
  end

  defp restart_after_protocol_failure(state, message) do
    state
    |> fail_active_task(message)
    |> begin_recovery("Pi protocol failed")
  end

  defp begin_recovery(state, message) do
    terminate_port(state.port, state.termination_timeout, state.port_pid)
    Process.send_after(self(), :start_port, state.restart_delay)

    %{
      state
      | port: nil,
        port_pid: nil,
        startup_id: nil,
        session_id: nil,
        pi_session_id: nil,
        model: nil,
        phase: :starting,
        error: message,
        buffer: "",
        restart_attempts: 0
    }
  end

  defp retry_startup(state, message) do
    terminate_port(state.port, state.termination_timeout, state.port_pid)
    state = %{state | port: nil, port_pid: nil, startup_id: nil, buffer: ""}

    if state.restart_attempts < state.max_restart_attempts do
      Process.send_after(self(), :start_port, state.restart_delay)
      %{state | phase: :starting, error: message}
    else
      state
      |> unavailable("Pi could not be restarted")
      |> fail_reset()
    end
  end

  defp recover_reset(%{reset_recovering: true} = state) do
    state
    |> unavailable("Pi could not recover the session reset")
    |> fail_reset()
  end

  defp recover_reset(state) do
    terminate_port(state.port, state.termination_timeout, state.port_pid)
    send(self(), :start_port)

    %{
      state
      | port: nil,
        port_pid: nil,
        startup_id: nil,
        session_id: nil,
        pi_session_id: nil,
        model: nil,
        buffer: "",
        phase: :resetting,
        reset_command_id: nil,
        reset_state_id: nil,
        reset_recovering: true,
        restart_attempts: 0
    }
  end

  defp complete_reset(state) do
    ready = clear_reset(%{state | task: nil})
    GenServer.reply(state.reset_from, {:ok, public_snapshot(ready)})
    ready
  end

  defp fail_reset(%{reset_from: nil} = state), do: state

  defp fail_reset(state) do
    GenServer.reply(state.reset_from, {:error, :unavailable, public_snapshot(state)})
    clear_reset(state)
  end

  defp clear_reset(state) do
    %{
      state
      | reset_command_id: nil,
        reset_state_id: nil,
        reset_from: nil,
        reset_recovering: false
    }
  end

  defp unavailable(state, message), do: %{state | phase: :unavailable, error: message}

  defp public_snapshot(state) do
    %{
      contract_version: 1,
      session: %{
        id: state.session_id,
        status: session_status(state.phase),
        model: state.model,
        error: state.error
      },
      task: public_task(state.task)
    }
  end

  defp public_task(nil), do: nil

  defp public_task(task) do
    %{
      id: task.id,
      prompt: task.prompt,
      status: Atom.to_string(task.status),
      output: task.output,
      output_truncated: task.output_truncated,
      activity: task.activity,
      error: task.error,
      started_at: DateTime.to_iso8601(task.started_at),
      finished_at: task.finished_at && DateTime.to_iso8601(task.finished_at)
    }
  end

  defp session_status(:starting), do: "starting"
  defp session_status(:ready), do: "ready"
  defp session_status(:busy), do: "busy"
  defp session_status(:resetting), do: "resetting"
  defp session_status(:unavailable), do: "unavailable"

  defp send_command(port, command) when is_port(port) do
    if Port.command(port, Jason.encode!(command) <> "\n"), do: :ok, else: {:error, :closed}
  rescue
    ArgumentError -> {:error, :closed}
  end

  defp send_command(_port, _command), do: {:error, :closed}

  defp terminate_port(nil, _timeout, nil), do: :ok
  defp terminate_port(nil, _timeout, pid), do: signal_process_group(pid, "KILL")

  defp terminate_port(port, timeout, known_pid) do
    pid =
      if is_port(port) do
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> known_pid
        end
      else
        known_pid
      end

    signal_process_group(pid, "TERM")
    exited? = await_port_exit(port, timeout)
    signal_process_group(pid, "KILL")
    unless exited?, do: await_port_exit(port, timeout)
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp signal_process_group(nil, _signal), do: :ok

  defp signal_process_group(pid, signal) do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        System.cmd(executable, ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    ErlangError -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp await_port_exit(port, timeout) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      timeout -> false
    end
  end

  defp resolve_executable(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      if File.exists?(path), do: path
    else
      System.find_executable(path)
    end
  end

  defp model_name(%{"provider" => provider, "id" => id})
       when is_binary(provider) and is_binary(id),
       do: safe_label("#{provider}/#{id}", nil, 256)

  defp model_name(model) when is_binary(model), do: safe_label(model, nil, 256)
  defp model_name(_model), do: nil

  defp safe_label(value, fallback, max_bytes \\ 100)

  defp safe_label(value, fallback, max_bytes) when is_binary(value) do
    value =
      value
      |> String.replace(
        ~r/[\x{0000}-\x{001f}\x{007f}-\x{009f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/u,
        " "
      )
      |> String.trim()
      |> String.replace(~r/\s+/u, " ")

    cond do
      value == "" -> fallback
      byte_size(value) <= max_bytes -> value
      true -> value |> binary_part(0, max_bytes) |> trim_invalid_suffix()
    end
  end

  defp safe_label(_value, fallback, _max_bytes), do: fallback

  defp trim_invalid_suffix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_suffix()
  end

  defp opaque_id do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp bounded_output(output) when byte_size(output) <= @max_output_bytes,
    do: {output, false}

  defp bounded_output(output) do
    suffix = binary_part(output, byte_size(output) - @max_output_bytes, @max_output_bytes)
    {trim_invalid_prefix(suffix), true}
  end

  defp trim_invalid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(1, byte_size(value) - 1) |> trim_invalid_prefix()
  end
end
