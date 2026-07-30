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
