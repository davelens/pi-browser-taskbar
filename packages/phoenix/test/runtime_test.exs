defmodule PiBrowserTaskbarPhoenix.RuntimeTest do
  use ExUnit.Case, async: false

  alias PiBrowserTaskbarPhoenix.Runtime
  alias PiBrowserTaskbarPhoenix.Task, as: BrowserTask

  @fixture Path.expand("../../../contract/fixtures/tasks/minimal-task.json", __DIR__)

  setup do
    name = String.to_atom("runtime_#{System.unique_integer([:positive])}")
    executable = Path.expand("support/fake_pi_rpc", __DIR__)

    start_supervised!(
      {Runtime,
       name: name,
       executable: executable,
       project_root: File.cwd!(),
       task_timeout: 60_000,
       allowed_hosts: []}
    )

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    %{runtime: name}
  end

  test "runs one whole-page task to completed fake-Pi output", %{runtime: runtime} do
    task = valid_task("Explain the cards page.")

    assert {:ok, running} = Runtime.submit(runtime, task)
    assert running.session.status == "busy"
    assert running.task.status == "running"
    assert opaque?(running.session.id)
    assert opaque?(running.task.id)

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    snapshot = Runtime.snapshot(runtime)

    assert snapshot.contract_version == 1
    assert snapshot.session.status == "ready"
    assert snapshot.session.model == "test/fake-pi"
    assert snapshot.task.output == "Implemented the whole-page request."
    assert snapshot.task.output_truncated == false
    assert snapshot.task.finished_at
  end

  test "cancels idempotently and finishes only at agent_settled", %{runtime: runtime} do
    assert {:error, :not_found, _snapshot} = Runtime.cancel(runtime, "unknown-task")

    assert {:ok, completed} = Runtime.submit(runtime, valid_task("completed task"))
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)

    assert {:error, :not_cancellable, _snapshot} =
             Runtime.cancel(runtime, completed.task.id)

    assert {:ok, running} = Runtime.submit(runtime, valid_task("hold this task"))
    assert {:ok, :accepted, cancelling} = Runtime.cancel(runtime, running.task.id)
    assert cancelling.session.status == "busy"
    assert cancelling.task.status == "cancelling"
    assert cancelling.task.finished_at == nil

    assert {:ok, :accepted, repeated} = Runtime.cancel(runtime, running.task.id)
    assert repeated.task.status == "cancelling"

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "cancelled" end)
    assert {:ok, :cancelled, cancelled} = Runtime.cancel(runtime, running.task.id)
    assert cancelled.session.status == "ready"
    assert cancelled.task.activity == "Task stopped"
    assert cancelled.task.finished_at
  end

  test "resets in process, rejects while busy, and preserves extension-rejected state", %{
    runtime: runtime
  } do
    assert {:ok, completed} = Runtime.submit(runtime, valid_task("completed before reset"))
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    old_session_id = completed.session.id
    old_port = :sys.get_state(runtime).port

    reset = Task.async(fn -> Runtime.reset(runtime) end)
    wait_until(fn -> Runtime.snapshot(runtime).session.status == "resetting" end)
    assert {:ok, fresh} = Task.await(reset)
    assert fresh.session.status == "ready"
    assert fresh.session.id != old_session_id
    assert fresh.task == nil
    assert :sys.get_state(runtime).port == old_port

    assert {:ok, running} = Runtime.submit(runtime, valid_task("hold this task"))
    assert {:error, :reset_while_busy, busy} = Runtime.reset(runtime)
    assert busy.task.id == running.task.id
    assert busy.task.status == "running"
    assert {:ok, :accepted, _snapshot} = Runtime.cancel(runtime, running.task.id)
    assert {:error, :reset_while_busy, cancelling} = Runtime.reset(runtime)
    assert cancelling.task.status == "cancelling"
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "cancelled" end)

    assert {:ok, rejected_task} = Runtime.submit(runtime, valid_task("reject reset"))
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    retained = Runtime.snapshot(runtime)
    assert retained.task.id == rejected_task.task.id

    assert {:error, :session_reset_rejected, rejected} = Runtime.reset(runtime)
    assert rejected == retained
  end

  test "recovers with process replacement only after RPC reset failure", %{runtime: runtime} do
    assert {:ok, _task} = Runtime.submit(runtime, valid_task("fail reset"))
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    old_session_id = Runtime.snapshot(runtime).session.id
    old_port = :sys.get_state(runtime).port

    assert {:ok, recovered} = Runtime.reset(runtime)
    assert recovered.session.status == "ready"
    assert recovered.session.id != old_session_id
    assert recovered.task == nil
    assert :sys.get_state(runtime).port != old_port
  end

  test "reports every progress event, cancels dialogs, and bounds UTF-8 output", %{
    runtime: runtime
  } do
    for {event, activity} <- [
          {"agent_start", "Pi is working"},
          {"agent_end", "Pi finished a turn"},
          {"tool_start", "Running read"},
          {"tool_update", "Running read"},
          {"tool_end", "Finished read"},
          {"compaction_start", "Compacting conversation"},
          {"compaction_end", "Retrying after compaction"},
          {"retry_start", "Retrying request (2/3)"},
          {"retry_end", "Pi is working"}
        ] do
      assert {:ok, running} = Runtime.submit(runtime, valid_task("activity #{event}"))
      wait_until(fn -> Runtime.snapshot(runtime).task.activity == activity end)
      assert Runtime.snapshot(runtime).task.status == "running", "#{event} completed the task"
      assert {:ok, :accepted, _snapshot} = Runtime.cancel(runtime, running.task.id)
      wait_until(fn -> Runtime.snapshot(runtime).task.status == "cancelled" end)
    end

    assert {:ok, dialog} = Runtime.submit(runtime, valid_task("dialog request"))
    Process.sleep(50)
    assert {:ok, :accepted, _snapshot} = Runtime.cancel(runtime, dialog.task.id)
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "cancelled" end)

    assert {:ok, _running} = Runtime.submit(runtime, valid_task("bounded output"))
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    task = Runtime.snapshot(runtime).task
    assert byte_size(task.output) == 32 * 1024
    assert String.valid?(task.output)
    assert String.ends_with?(task.output, "🙂z")
    assert task.output_truncated
  end

  test "reports safe terminal and protocol failures and recovers", %{runtime: runtime} do
    for {prompt, safe_error} <- [
          {"rejected command", "Pi rejected the task"},
          {"message error", "Pi reported a message error"},
          {"retry failure", "Pi could not complete the task after retries"},
          {"compaction failure", "Pi could not compact the conversation"},
          {"unexpected response", "Pi returned an unexpected RPC response"},
          {"malformed record", "Pi sent a malformed RPC record"},
          {"oversized record", "Pi sent an oversized RPC record"},
          {"non-object record", "Pi sent a non-object RPC record"}
        ] do
      assert {:ok, _running} = Runtime.submit(runtime, valid_task(prompt))
      wait_until(fn -> Runtime.snapshot(runtime).task.status == "failed" end)
      assert Runtime.snapshot(runtime).task.error == safe_error
      refute Runtime.snapshot(runtime).task.error =~ "raw provider"
      wait_until(fn -> Runtime.snapshot(runtime).session.status == "ready" end)
    end
  end

  test "spawns Pi directly in the canonical root with the one-shot execution policy" do
    name = String.to_atom("runtime_spawn_#{System.unique_integer([:positive])}")

    directory =
      Path.join(
        System.tmp_dir!(),
        "pi-browser-taskbar-spawn-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    executable = Path.join(directory, "fake-pi")

    File.write!(executable, """
    #!/usr/bin/env ruby
    require "json"
    File.write(File.join(Dir.pwd, "spawn-evidence.json"), JSON.generate("cwd" => Dir.pwd, "argv" => ARGV))
    $stdin.each_line do |line|
      command = JSON.parse(line)
      next unless command.fetch("type") == "get_state"
      puts JSON.generate(type: "response", id: command.fetch("id"), success: true,
        data: {sessionId: "spawn-session", model: "fake"})
      $stdout.flush
    end
    """)

    File.chmod!(executable, 0o700)

    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         name: name, executable: executable, project_root: directory, task_timeout: 60_000},
        id: name
      )
    )

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    evidence = directory |> Path.join("spawn-evidence.json") |> File.read!() |> Jason.decode!()

    assert evidence["cwd"] == Path.expand(directory)

    assert evidence["argv"] == [
             "--mode",
             "rpc",
             "--append-system-prompt",
             "You are handling a one-shot browser task with no reply channel. Complete the user's request autonomously without asking follow-up questions. Inspect the repository and use the supplied browser context. Resolve missing details with conservative assumptions. Act directly on implementation requests, but preserve explicit planning and read-only constraints. Do not repeat a failed approach unchanged. If safe completion is impossible, stop and report the exact blocker."
           ]
  end

  test "requires startup model state before accepting work" do
    name = String.to_atom("runtime_missing_model_#{System.unique_integer([:positive])}")

    directory =
      Path.join(System.tmp_dir!(), "pi-browser-taskbar-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    executable = Path.join(directory, "fake-pi")

    File.write!(executable, """
    #!/usr/bin/env ruby
    require "json"
    command = JSON.parse($stdin.gets)
    puts JSON.generate(type: "response", id: command.fetch("id"), success: true, data: {sessionId: "missing-model"})
    $stdout.flush
    sleep 5
    """)

    File.chmod!(executable, 0o700)

    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         name: name, executable: executable, project_root: directory, task_timeout: 60_000},
        id: name
      )
    )

    wait_until(fn -> Runtime.snapshot(name).session.status == "unavailable" end)
    assert Runtime.snapshot(name).session.error == "Pi returned invalid startup state"
    assert {:error, :unavailable, _snapshot} = Runtime.submit(name, valid_task("not accepted"))
  end

  test "restarts after an oversized RPC record", %{runtime: runtime} do
    assert {:ok, _running} = Runtime.submit(runtime, valid_task("oversized record"))

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "failed" end)
    wait_until(fn -> Runtime.snapshot(runtime).session.status == "ready" end)

    assert Runtime.snapshot(runtime).task.error == "Pi sent an oversized RPC record"
  end

  test "restarts after a malformed RPC record", %{runtime: runtime} do
    assert {:ok, _running} = Runtime.submit(runtime, valid_task("malformed record"))

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "failed" end)
    wait_until(fn -> Runtime.snapshot(runtime).session.status == "ready" end)

    assert Runtime.snapshot(runtime).task.error == "Pi sent a malformed RPC record"
  end

  test "restarts after a non-object RPC record", %{runtime: runtime} do
    assert {:ok, _running} = Runtime.submit(runtime, valid_task("non-object record"))

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "failed" end)
    wait_until(fn -> Runtime.snapshot(runtime).session.status == "ready" end)

    assert Runtime.snapshot(runtime).task.error == "Pi sent a non-object RPC record"
  end

  test "times out tasks and cancellation with bounded process-tree replacement" do
    {name, directory} =
      recovery_runtime(
        """
        trap("TERM", "IGNORE")
        child_file = File.join(Dir.pwd, "owned-child")
        $stdin.each_line do |line|
          command = JSON.parse(line)
          if command.fetch("type") == "get_state"
            puts JSON.generate(type: "response", id: command.fetch("id"), success: true,
              data: {sessionId: "session-\#{Process.pid}", model: "fake"})
          elsif command.fetch("type") == "prompt"
            puts JSON.generate(type: "response", id: command.fetch("id"), success: true)
            child = fork { trap("TERM", "IGNORE"); sleep 60 }
            File.write(child_file, child)
          elsif command.fetch("type") == "abort"
            puts JSON.generate(type: "response", id: command.fetch("id"), success: true)
          end
          $stdout.flush
        end
        """,
        task_timeout: 40,
        abort_timeout: 40,
        termination_timeout: 40
      )

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    first_session = Runtime.snapshot(name).session.id
    old_port_pid = port_pid(name)
    assert {:ok, _running} = Runtime.submit(name, valid_task("timeout scenario"))
    wait_until(fn -> Runtime.snapshot(name).task.status == "failed" end)
    timed_out = Runtime.snapshot(name)
    assert timed_out.task.error == "Pi task exceeded the configured time limit"
    assert timed_out.session.status == "starting"
    assert timed_out.session.id == nil

    old_child =
      directory
      |> Path.join("owned-child")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    refute Runtime.snapshot(name).session.id == first_session
    refute os_process_alive?(old_port_pid)
    refute os_process_alive?(old_child)

    second_session = Runtime.snapshot(name).session.id
    assert {:ok, running} = Runtime.submit(name, valid_task("abort deadline scenario"))
    assert {:ok, :accepted, _snapshot} = Runtime.cancel(name, running.task.id)
    wait_until(fn -> Runtime.snapshot(name).task.status == "cancelled" end)
    cancelled = Runtime.snapshot(name)
    assert cancelled.task.error == "Pi did not stop before the cancellation deadline"
    assert cancelled.session.id == nil
    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    refute Runtime.snapshot(name).session.id == second_session
    replacement_pid = port_pid(name)
    stop_supervised(name)
    refute os_process_alive?(replacement_pid)
  end

  test "recovers useful task evidence after a crash and exhausts bounded restart attempts" do
    {name, directory} =
      recovery_runtime(
        """
        count_file = File.join(Dir.pwd, "start-count")
        count = File.exist?(count_file) ? File.read(count_file).to_i + 1 : 1
        File.write(count_file, count)
        startup = JSON.parse($stdin.gets)
        puts JSON.generate(type: "response", id: startup.fetch("id"), success: true,
          data: {sessionId: "session-\#{count}", model: "fake"})
        $stdout.flush
        if count == 1
          prompt = JSON.parse($stdin.gets)
          puts JSON.generate(type: "response", id: prompt.fetch("id"), success: true)
          puts JSON.generate(type: "message_update",
            assistantMessageEvent: {type: "text_delta", delta: "useful partial output"})
          $stdout.flush
          exit! 7
        end
        sleep 60
        """,
        restart_delay: 80
      )

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    old_session = Runtime.snapshot(name).session.id
    assert {:ok, _running} = Runtime.submit(name, valid_task("crash during work"))
    wait_until(fn -> Runtime.snapshot(name).task.status == "failed" end)
    crashed = Runtime.snapshot(name)
    assert crashed.task.output == "useful partial output"
    assert crashed.task.error == "Pi stopped unexpectedly"
    assert crashed.session.status == "starting"
    assert crashed.session.id == nil
    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    refute Runtime.snapshot(name).session.id == old_session
    assert File.read!(Path.join(directory, "start-count")) == "2"
    replacement_pid = port_pid(name)
    stop_supervised(name)
    refute os_process_alive?(replacement_pid)

    {exhausted, exhausted_directory} =
      recovery_runtime(
        """
        File.open(File.join(Dir.pwd, "start-count"), "a") { |file| file.puts(Process.pid) }
        exit! 9
        """,
        max_restart_attempts: 2,
        restart_delay: 10
      )

    wait_until(fn -> Runtime.snapshot(exhausted).session.status == "unavailable" end)
    assert Runtime.snapshot(exhausted).session.error == "Pi could not be restarted"

    assert length(
             File.read!(Path.join(exhausted_directory, "start-count"))
             |> String.split("\n", trim: true)
           ) == 2

    stop_supervised(exhausted)
  end

  test "recovers an idle crash and keeps a non-executable Pi unavailable without crashing the host" do
    {name, _directory} =
      recovery_runtime(
        """
        count_file = File.join(Dir.pwd, "start-count")
        count = File.exist?(count_file) ? File.read(count_file).to_i + 1 : 1
        File.write(count_file, count)
        startup = JSON.parse($stdin.gets)
        puts JSON.generate(type: "response", id: startup.fetch("id"), success: true,
          data: {sessionId: "session-\#{count}", model: "fake"})
        $stdout.flush
        count == 1 ? sleep(0.08) : sleep(60)
        """,
        restart_delay: 300
      )

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    old_session = Runtime.snapshot(name).session.id
    wait_until(fn -> Runtime.snapshot(name).session.status == "starting" end)
    assert Runtime.snapshot(name).session.id == nil
    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    refute Runtime.snapshot(name).session.id == old_session
    assert Runtime.snapshot(name).task == nil
    replacement_pid = port_pid(name)
    stop_supervised(name)
    refute os_process_alive?(replacement_pid)

    directory =
      Path.join(
        System.tmp_dir!(),
        "pi-browser-taskbar-nonexec-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    executable = Path.join(directory, "pi")
    File.write!(executable, "not executable")
    missing = String.to_atom("runtime_nonexec_#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         name: missing,
         executable: executable,
         project_root: directory,
         max_restart_attempts: 2,
         restart_delay: 10},
        id: missing
      )
    )

    wait_until(fn -> Runtime.snapshot(missing).session.status == "unavailable" end)
    assert Process.alive?(Process.whereis(missing))
    assert Runtime.snapshot(missing).session.error == "Pi could not be restarted"
  end

  test "admits a busy task atomically", %{runtime: runtime} do
    assert {:ok, running} = Runtime.submit(runtime, valid_task("hold this task"))

    submissions =
      1..8
      |> Task.async_stream(fn _ -> Runtime.submit(runtime, valid_task("second task")) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(submissions, &match?({:error, :busy, _snapshot}, &1))
    assert Runtime.snapshot(runtime).task.id == running.task.id
  end

  defp valid_task(prompt) do
    params = @fixture |> File.read!() |> Jason.decode!() |> Map.put("prompt", prompt)
    {:ok, task} = BrowserTask.new(params)
    task
  end

  defp opaque?(value), do: is_binary(value) and byte_size(value) >= 16

  defp recovery_runtime(body, options) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "pi-browser-taskbar-recovery-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    executable = Path.join(directory, "fake-pi")
    File.write!(executable, "#!/usr/bin/env ruby\nrequire \"json\"\n" <> body)
    File.chmod!(executable, 0o700)
    name = String.to_atom("runtime_recovery_#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         options ++
           [
             name: name,
             executable: executable,
             project_root: directory,
             task_timeout: 60_000,
             abort_timeout: 5_000,
             termination_timeout: 50,
             max_restart_attempts: 3,
             restart_delay: 20
           ]},
        id: name
      )
    )

    {name, directory}
  end

  defp port_pid(runtime) do
    {:os_pid, pid} = Port.info(:sys.get_state(runtime).port, :os_pid)
    pid
  end

  defp os_process_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp wait_until(predicate, attempts \\ 300)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0), do: flunk("condition was not met in time")
end
