# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/pi/browser/taskbar/rails/broker"

class RailsBrokerTest < Minitest::Test
  Broker = Pi::Browser::Taskbar::Rails::Broker
  FAKE_PI = File.expand_path("support/fake_pi_rpc", __dir__)
  TASK = File.expand_path("../../../contract/fixtures/tasks/minimal-task.json", __dir__)

  def test_identity_is_canonical_private_and_checkout_scoped
    Dir.mktmpdir("broker-root") do |runtime_root|
      Dir.mktmpdir("broker-project") do |project|
        identity = Broker::Identity.new(project, runtime_root: runtime_root)
        same = Broker::Identity.new(File.join(project, "."), runtime_root: runtime_root)
        assert_equal identity.key, same.key
        assert_equal "#{Process.uid}:#{File.realpath(project)}", identity.identity
        assert_equal 0, File.stat(runtime_root).mode & 0o077
        assert_includes identity.socket_path, identity.key
      end
      Dir.mktmpdir("other-project") do |other|
        refute_equal Broker::Identity.new(other, runtime_root: runtime_root).key,
          Broker::Identity.new(Dir.pwd, runtime_root: runtime_root).key
      end
    end
  end

  def test_identity_rejects_symlinked_runtime_directories_without_chmodding_targets
    Dir.mktmpdir("broker-parent") do |parent|
      Dir.mktmpdir("broker-project") do |project|
        target = File.join(parent, "target")
        Dir.mkdir(target, 0o700)
        File.chmod(0o777, target)
        root = File.join(parent, "runtime")
        File.symlink(target, root)

        assert_raises(Broker::Unavailable) { Broker::Identity.new(project, runtime_root: root) }
        assert_equal 0o777, File.stat(target).mode & 0o777

        File.unlink(root)
        Dir.mkdir(root, 0o700)
        key = Digest::SHA256.hexdigest("#{Process.uid}\0#{File.realpath(project)}")[0, 32]
        checkout_target = File.join(parent, "checkout-target")
        Dir.mkdir(checkout_target, 0o700)
        File.chmod(0o777, checkout_target)
        File.symlink(checkout_target, File.join(root, key))

        assert_raises(Broker::Unavailable) { Broker::Identity.new(project, runtime_root: root) }
        assert_equal 0o777, File.stat(checkout_target).mode & 0o777
      end
    end
  end

  def test_election_metadata_handshake_fake_pi_completion_and_atomic_admission
    with_server do |client, second, identity, thread, startup_count|
      metadata = JSON.parse(File.read(identity.metadata_path))
      assert_equal 1, metadata["protocol"]
      assert_equal identity.identity, metadata["identity"]
      assert_operator metadata["token"].length, :>=, 32
      assert_equal 0, File.stat(identity.metadata_path).mode & 0o077
      assert File.socket?(identity.socket_path)

      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }
      assert_equal 1, File.readlines(startup_count).length
      assert_equal client.snapshot.dig("snapshot", "session", "id"), second.snapshot.dig("snapshot", "session", "id")

      held = JSON.parse(File.read(TASK))
      held["prompt"] = "hold this task"
      results = [client, second].map { |item| Thread.new { item.submit(held) } }.map(&:value)
      assert_equal ["accepted", "busy"], results.map { |item| item["result"] }.sort

      client.close
      second.close
      assert thread.join(2), "broker did not honor zero-client grace"
    end

    with_server do |client, _second, _identity, _thread|
      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }
      response = client.submit(JSON.parse(File.read(TASK)))
      assert_equal "accepted", response["result"]
      wait_until { client.snapshot.dig("snapshot", "task", "status") == "completed" }
      assert_equal "Implemented the whole-page request.", client.snapshot.dig("snapshot", "task", "output")
    end
  end

  def test_cancellation_is_idempotent_and_finishes_only_at_agent_settled
    with_server do |client, _second, _identity, _thread|
      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }

      missing = client.cancel("unknown-task")
      assert_equal "not_found", missing["result"]

      completed = client.submit(JSON.parse(File.read(TASK)))
      wait_until { client.snapshot.dig("snapshot", "task", "status") == "completed" }
      assert_equal "not_cancellable", client.cancel(completed.dig("snapshot", "task", "id"))["result"]

      held = JSON.parse(File.read(TASK)).merge("prompt" => "hold this task")
      running = client.submit(held)
      task_id = running.dig("snapshot", "task", "id")

      accepted = client.cancel(task_id)
      repeated = client.cancel(task_id)
      assert_equal "accepted", accepted["result"]
      assert_equal "cancelling", accepted.dig("snapshot", "task", "status")
      assert_equal "accepted", repeated["result"]
      assert_nil repeated.dig("snapshot", "task", "finished_at")

      wait_until { client.snapshot.dig("snapshot", "task", "status") == "cancelled" }
      cancelled = client.cancel(task_id)
      assert_equal "cancelled", cancelled["result"]
      assert_equal "ready", cancelled.dig("snapshot", "session", "status")
      assert_equal "Task stopped", cancelled.dig("snapshot", "task", "activity")
      refute_nil cancelled.dig("snapshot", "task", "finished_at")
    end
  end

  def test_losing_election_does_not_clean_up_the_live_owner
    with_server do |client, _second, identity, thread|
      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }
      metadata = File.read(identity.metadata_path)

      contender = Broker::Server.new(identity: identity, executable: FAKE_PI, grace: 0)
      refute contender.run

      assert thread.alive?
      assert File.socket?(identity.socket_path)
      assert_equal metadata, File.read(identity.metadata_path)
      assert_equal "ready", client.snapshot.dig("snapshot", "session", "status")
    end
  end

  def test_broker_rejects_unknown_and_malformed_commands_before_dispatch
    with_server do |client, _second, identity, _thread|
      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }
      peer = connect_peer(identity)

      write_peer(peer, "type" => "explode", "id" => "a" * 24)
      assert_equal "unknown broker command", read_peer(peer)["message"]

      write_peer(peer, "type" => "state", "id" => "b" * 24, "extra" => true)
      assert_equal "malformed broker command", read_peer(peer)["message"]

      write_peer(peer, "type" => "submit", "id" => "c" * 24, "task" => {})
      parsed = read_peer(peer)
      assert_equal "invalid", parsed["result"]
      assert_match(/task is missing field/, parsed["message"])
      assert_equal "ready", client.snapshot.dig("snapshot", "session", "status")
    ensure
      peer.close if peer
    end
  end

  def test_pi_stderr_does_not_corrupt_json_rpc
    with_server do |client, _second, _identity, _thread|
      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }
      task = JSON.parse(File.read(TASK)).merge("prompt" => "stderr output")

      assert_equal "accepted", client.submit(task)["result"]
      wait_until { client.snapshot.dig("snapshot", "task", "status") == "completed" }
      assert_equal "Implemented the whole-page request.", client.snapshot.dig("snapshot", "task", "output")
    end
  end

  def test_non_object_pi_record_fails_startup_instead_of_hanging
    with_runtime_fake(<<~RUBY) do |runtime|
      #!/usr/bin/env ruby
      $stdin.gets
      puts "null"
      $stdout.flush
      sleep 5
    RUBY
      wait_until { runtime.snapshot.dig("session", "status") == "unavailable" }
      assert_equal "Pi protocol failed", runtime.snapshot.dig("session", "error")
    end
  end

  def test_unexpected_pi_eof_fails_an_accepted_task
    with_runtime_fake(<<~RUBY) do |runtime|
      #!/usr/bin/env ruby
      require "json"
      startup = JSON.parse($stdin.gets)
      puts JSON.generate(type: "response", id: startup.fetch("id"), success: true, data: {model: "fake"})
      $stdout.flush
      $stdin.gets
    RUBY
      wait_until { runtime.snapshot.dig("session", "status") == "ready" }
      result, = runtime.submit(JSON.parse(File.read(TASK)))
      assert_equal :accepted, result
      wait_until { runtime.snapshot.dig("session", "status") == "unavailable" }

      task = runtime.snapshot.fetch("task")
      assert_equal "failed", task["status"]
      assert_equal "Pi stopped unexpectedly", task["error"]
      refute_nil task["finished_at"]
    end
  end

  def test_incompatible_handshake_is_unavailable_without_fallback
    Dir.mktmpdir("broker-runtime") do |runtime_root|
      Dir.mktmpdir("broker-project") do |project|
        identity = Broker::Identity.new(project, runtime_root: runtime_root)
        socket = UNIXServer.new(identity.socket_path)
        metadata = {"protocol" => 1, "identity" => identity.identity, "token" => "wrong", "socket" => identity.socket_path, "pid" => Process.pid}
        File.write(identity.metadata_path, JSON.generate(metadata))
        responder = Thread.new do
          peer = socket.accept
          peer.gets
          peer.puts JSON.generate(type: "error", code: "incompatible")
          peer.close
        end
        client = Broker::Client.new(project_root: project, runtime_root: runtime_root, executable: "/must/not/start")
        assert_raises(Broker::Unavailable) { client.snapshot }
        responder.join
        socket.close
      end
    end
  end

  def test_client_closes_a_socket_when_handshake_parsing_fails
    Dir.mktmpdir("broker-runtime") do |runtime_root|
      Dir.mktmpdir("broker-project") do |project|
        identity = Broker::Identity.new(project, runtime_root: runtime_root)
        listener = UNIXServer.new(identity.socket_path)
        metadata = {"protocol" => 1, "identity" => identity.identity, "token" => "token", "socket" => identity.socket_path}
        responder = Thread.new do
          peer = listener.accept
          peer.gets
          peer.puts "{not-json"
          peer.read.empty?
        ensure
          peer.close if peer
        end
        client = Broker::Client.new(project_root: project, runtime_root: runtime_root)

        assert_equal :missing, client.send(:connect_metadata, metadata)
        assert responder.value
      ensure
        client.close if client
        listener.close if listener
      end
    end
  end

  def test_client_discards_inherited_connection_and_reconnects_after_fork
    skip "fork unavailable" unless Process.respond_to?(:fork)
    with_server do |client, _second, _identity, _thread|
      wait_until { client.snapshot.dig("snapshot", "session", "status") == "ready" }
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        inherited = client.instance_variable_get(:@socket)
        child_session = client.snapshot.dig("snapshot", "session", "id")
        writer.write(Marshal.dump([child_session, inherited.closed?]))
        writer.close
        exit! 0
      end
      writer.close
      child_session, inherited_closed = Marshal.load(reader.read)
      Process.wait(pid)
      assert inherited_closed
      assert_equal client.snapshot.dig("snapshot", "session", "id"), child_session
    end
  end

  private

  def connect_peer(identity)
    metadata = JSON.parse(File.read(identity.metadata_path))
    peer = UNIXSocket.new(identity.socket_path)
    write_peer(peer, "type" => "handshake", "protocol" => 1, "identity" => identity.identity, "token" => metadata.fetch("token"))
    assert_equal "handshake", read_peer(peer)["type"]
    peer
  end

  def write_peer(peer, value)
    peer.puts(JSON.generate(value))
  end

  def read_peer(peer)
    JSON.parse(peer.gets)
  end

  def with_runtime_fake(source)
    Dir.mktmpdir("broker-runtime-fake") do |directory|
      project = File.join(directory, "project")
      Dir.mkdir(project)
      executable = File.join(directory, "fake-pi")
      File.write(executable, source)
      File.chmod(0o700, executable)
      runtime = Broker::Runtime.new(project_root: project, executable: executable)
      yield runtime
    ensure
      runtime.close if runtime
    end
  end

  def with_server
    Dir.mktmpdir("broker-runtime") do |runtime_root|
      Dir.mktmpdir("broker-project") do |project|
        identity = Broker::Identity.new(project, runtime_root: runtime_root)
        startup_count = File.join(runtime_root, "pi-startups")
        executable = File.join(runtime_root, "counted-fake-pi")
        File.write(executable, <<~RUBY)
          #!/usr/bin/env ruby
          File.open(#{startup_count.inspect}, "a") { |file| file.puts(Process.pid) }
          exec(#{FAKE_PI.inspect}, *ARGV)
        RUBY
        File.chmod(0o700, executable)
        server = Broker::Server.new(identity: identity, executable: executable, grace: 0.15)
        thread = Thread.new { server.run }
        wait_until { File.file?(identity.metadata_path) }
        first = Broker::Client.new(project_root: project, runtime_root: runtime_root, executable: executable)
        second = Broker::Client.new(project_root: project, runtime_root: runtime_root, executable: executable)
        yield first, second, identity, thread, startup_count
      ensure
        first.close if first
        second.close if second
        thread.join(2) if thread
      end
    end
  end

  def wait_until(attempts = 300)
    attempts.times do
      return true if yield
      sleep 0.01
    end
    flunk "timed out"
  end
end
