defmodule PiBrowserTaskbarPhoenix.Runtime do
  @moduledoc """
  Owns one persistent Pi RPC process and serializes task admission for a host project.
  """

  use GenServer

  require Logger

  alias PiBrowserTaskbarPhoenix.Task, as: BrowserTask

  @max_record_bytes 1_000_000
  @max_output_bytes 32 * 1024

  defstruct [
    :name,
    :port,
    :executable,
    :project_root,
    :task_timeout,
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
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      executable: resolve_executable(Keyword.get(opts, :executable, "pi")),
      project_root: Keyword.fetch!(opts, :project_root),
      task_timeout: Keyword.get(opts, :task_timeout, 30 * 60_000),
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
        next = unavailable(state, "Pi became unavailable before accepting the task")
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

        next = %{state | task: task}
        {:reply, {:ok, :accepted, public_snapshot(next)}, next}

      {:error, :closed} ->
        next = unavailable(state, "Pi became unavailable before accepting cancellation")
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
    case open_port(state) do
      {:ok, port} ->
        startup_id = "startup-#{opaque_id()}"

        case send_command(port, %{type: "get_state", id: startup_id}) do
          :ok ->
            {:noreply,
             %{
               state
               | port: port,
                 startup_id: startup_id,
                 phase: :starting,
                 buffer: "",
                 error: nil
             }}

          {:error, :closed} ->
            close_port(port)
            {:noreply, unavailable(state, "Pi stopped during startup")}
        end

      {:error, _reason} ->
        next = unavailable(state, "Pi could not be started")
        {:noreply, fail_reset(next)}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume_data(state, data)}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port, phase: :resetting} = state) do
    {:noreply, recover_reset(%{state | port: nil})}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    state =
      state
      |> fail_active_task("Pi stopped unexpectedly")
      |> unavailable("Pi stopped unexpectedly")

    Process.send_after(self(), :start_port, 1_000)
    {:noreply, %{state | port: nil}}
  end

  def handle_info({:task_timeout, id}, %{phase: :busy, task: %{id: id}} = state) do
    close_port(state.port)

    state =
      state
      |> fail_active_task("Pi task exceeded the configured time limit")
      |> unavailable("Pi is restarting")

    Process.send_after(self(), :start_port, 100)
    {:noreply, %{state | port: nil}}
  end

  def handle_info({:task_timeout, _id}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp open_port(state) do
    {:ok,
     Port.open(
       {:spawn_executable, state.executable},
       [:binary, :exit_status, :use_stdio, args: ["--mode", "rpc"], cd: state.project_root]
     )}
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :open_failed}
  end

  defp consume_data(state, data) do
    buffer = state.buffer <> data

    if byte_size(buffer) > @max_record_bytes do
      restart_after_protocol_failure(state, "Pi sent an oversized RPC record")
    else
      {lines, remainder} = split_lines(buffer)

      consumed =
        Enum.reduce_while(lines, state, fn line, current ->
          next = consume_line(line, current)
          if next.port, do: {:cont, next}, else: {:halt, next}
        end)

      if consumed.port, do: %{consumed | buffer: remainder}, else: consumed
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
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
         "type" => "response",
         "id" => id,
         "success" => true,
         "data" => %{"sessionId" => pi_session_id} = data
       })
       when id == state.startup_id and is_binary(pi_session_id) and pi_session_id != "" do
    ready = %{
      state
      | phase: :ready,
        session_id: opaque_id(),
        pi_session_id: pi_session_id,
        model: model_name(data["model"]),
        error: nil
    }

    if state.reset_from, do: complete_reset(ready), else: ready
  end

  defp handle_event(state, %{"type" => "response", "id" => id, "success" => false})
       when id == state.startup_id do
    state
    |> unavailable("Pi rejected its startup handshake")
    |> fail_reset()
  end

  defp handle_event(state, %{"type" => "response", "id" => id}) when id == state.startup_id do
    state
    |> unavailable("Pi returned invalid startup state")
    |> fail_reset()
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
    if pi_session_id == state.pi_session_id do
      recover_reset(state)
    else
      state
      |> Map.merge(%{
        phase: :ready,
        session_id: opaque_id(),
        pi_session_id: pi_session_id,
        model: model_name(data["model"]),
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
         "success" => false
       })
       when not is_nil(command_id) do
    finish_task(state, :failed, "Pi rejected cancellation")
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

  defp handle_event(%{phase: :busy, task: %{status: :running}} = state, %{
         "type" => "tool_execution_start",
         "toolName" => name
       })
       when is_binary(name) do
    put_in(state.task.activity, "Running #{name}")
  end

  defp handle_event(%{phase: :busy, task: %{status: :cancelling}} = state, %{
         "type" => "agent_settled"
       }) do
    finish_task(state, :cancelled, nil)
  end

  defp handle_event(%{phase: :busy} = state, %{"type" => "agent_settled"}) do
    finish_task(state, :completed, nil)
  end

  defp handle_event(state, _event), do: state

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

  defp restart_after_protocol_failure(state, message) do
    close_port(state.port)
    Process.send_after(self(), :start_port, 100)

    failed = state |> fail_active_task(message) |> unavailable("Pi protocol failed")
    %{failed | port: nil, buffer: ""}
  end

  defp recover_reset(%{reset_recovering: true} = state) do
    state
    |> unavailable("Pi could not recover the session reset")
    |> fail_reset()
  end

  defp recover_reset(state) do
    close_port(state.port)
    send(self(), :start_port)

    %{
      state
      | port: nil,
        buffer: "",
        phase: :resetting,
        reset_command_id: nil,
        reset_state_id: nil,
        reset_recovering: true
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

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
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
       do: "#{provider}/#{id}"

  defp model_name(model) when is_binary(model), do: model
  defp model_name(_model), do: nil

  defp opaque_id do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp bounded_output(output) when byte_size(output) <= @max_output_bytes,
    do: {output, false}

  defp bounded_output(output) do
    {_discarded, suffix} = String.split_at(output, 1)
    {bounded, _truncated?} = bounded_output(suffix)
    {bounded, true}
  end
end
