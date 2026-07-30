# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "thread"
require "time"
require "tmpdir"
require_relative "task"

module Pi
  module Browser
    module Taskbar
      module Rails
        module Broker
          PROTOCOL_VERSION = 1
          MAX_RECORD_BYTES = 1_000_000

          class Unavailable < StandardError; end

          class Identity
            attr_reader :project_root, :uid, :key, :directory

            def initialize(project_root, runtime_root: nil)
              @project_root = File.realpath(project_root)
              @uid = Process.uid
              @key = Digest::SHA256.hexdigest("#{uid}\0#{@project_root}")[0, 32]
              root = runtime_root || default_runtime_root
              secure_directory(root)
              @directory = File.join(root, key)
              secure_directory(@directory)
            rescue SystemCallError => error
              raise Unavailable, "broker identity is unavailable: #{error.message}"
            end

            def identity
              "#{uid}:#{project_root}"
            end

            def lock_path
              File.join(directory, "broker.lock")
            end

            def socket_path
              File.join(directory, "broker.sock")
            end

            def metadata_path
              File.join(directory, "endpoint.json")
            end

            private

            def default_runtime_root
              candidate = ENV["XDG_RUNTIME_DIR"]
              if candidate && private_directory?(candidate)
                File.join(candidate, "pi-browser-taskbar")
              else
                File.join(Dir.tmpdir, "pi-browser-taskbar-#{uid}")
              end
            end

            def private_directory?(path)
              stat = File.lstat(path)
              stat.directory? && !stat.symlink? && stat.uid == uid && (stat.mode & 0o077).zero?
            rescue SystemCallError
              false
            end

            def secure_directory(path)
              begin
                Dir.mkdir(path, 0o700)
              rescue Errno::EEXIST
                nil
              end

              stat = File.lstat(path)
              raise Unavailable, "broker runtime path is not a user-owned directory" unless stat.directory? && !stat.symlink? && stat.uid == uid

              flags = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
              File.open(path, flags) do |directory|
                opened = directory.stat
                current = File.lstat(path)
                unless opened.directory? && opened.uid == uid && current.dev == opened.dev && current.ino == opened.ino
                  raise Unavailable, "broker runtime path changed while being secured"
                end
                directory.chmod(0o700)
                raise Unavailable, "broker runtime directory is not private" unless (directory.stat.mode & 0o077).zero?
              end
            end
          end

          class Runtime
            def initialize(project_root:, executable:, task_timeout: 1_800)
              @project_root = project_root
              @executable = executable
              @task_timeout = task_timeout
              @mutex = Mutex.new
              @write_mutex = Mutex.new
              @session_id = nil
              @model = nil
              @error = nil
              @task = nil
              @phase = "starting"
              @reset_condition = ConditionVariable.new
              @reset_result = nil
              @reset_recovering = false
              start_pi
            end

            def snapshot
              @mutex.synchronize { snapshot_unlocked }
            end

            def submit(value)
              task = Task.parse(value)
              @mutex.synchronize do
                return [:busy, snapshot_unlocked] if @phase == "busy"
                return [:unavailable, snapshot_unlocked] unless @phase == "ready"

                id = SecureRandom.urlsafe_base64(18, false)
                now = Time.now.utc.iso8601(6)
                @task = {
                  "id" => id, "prompt" => task.prompt, "status" => "running", "output" => "",
                  "output_truncated" => false, "activity" => "Starting Pi", "error" => nil,
                  "started_at" => now, "finished_at" => nil, "command_id" => "task-#{id}"
                }
                @phase = "busy"
                write(type: "prompt", id: @task["command_id"], message: task.pi_prompt)
                Thread.new do
                  sleep @task_timeout
                  timeout(id)
                end
                [:accepted, snapshot_unlocked]
              rescue IOError, SystemCallError
                unavailable_unlocked("Pi became unavailable before accepting the task")
                [:unavailable, snapshot_unlocked]
              end
            rescue Task::Invalid => error
              [:invalid, error.message]
            end

            def cancel(id)
              @mutex.synchronize do
                return [:not_found, snapshot_unlocked] unless @task && @task["id"] == id

                case @task["status"]
                when "running"
                  @task["abort_command_id"] = "abort-#{@task["id"]}"
                  write(type: "abort", id: @task["abort_command_id"])
                  @task["status"] = "cancelling"
                  @task["activity"] = "Stopping Pi"
                  [:accepted, snapshot_unlocked]
                when "cancelling"
                  [:accepted, snapshot_unlocked]
                when "cancelled"
                  [:cancelled, snapshot_unlocked]
                else
                  [:not_cancellable, snapshot_unlocked]
                end
              rescue IOError, SystemCallError
                unavailable_unlocked("Pi became unavailable before accepting cancellation")
                [:unavailable, snapshot_unlocked]
              end
            end

            def reset
              @mutex.synchronize do
                return [:reset_while_busy, snapshot_unlocked] unless @phase == "ready"

                @phase = "resetting"
                @reset_result = nil
                @reset_command_id = "reset-#{SecureRandom.urlsafe_base64(18, false)}"
                begin
                  write(type: "new_session", id: @reset_command_id)
                rescue IOError, SystemCallError
                  recover_reset_unlocked
                end
                @reset_condition.wait(@mutex) while @phase == "resetting"
                [@reset_result, snapshot_unlocked]
              end
            end

            def close
              @mutex.synchronize { stop_pi_unlocked }
            rescue IOError, SystemCallError
              nil
            end

            private

            def start_pi
              @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@executable, "--mode", "rpc", chdir: @project_root)
              stdout = @stdout
              stderr = @stderr
              @stderr_reader = Thread.new { drain_stderr(stderr) }
              @startup_id = "startup-#{SecureRandom.urlsafe_base64(18, false)}"
              write(type: "get_state", id: @startup_id)
              @reader = Thread.new { read_events(stdout) }
            rescue IOError, SystemCallError
              unavailable_unlocked("Pi executable was not found or could not be started")
              finish_reset_unlocked(:unavailable) if @reset_recovering
            end

            def drain_stderr(stderr)
              loop { stderr.readpartial(16 * 1024) }
            rescue EOFError, IOError
              nil
            end

            def read_events(stdout)
              loop do
                line = stdout.gets("\n", MAX_RECORD_BYTES + 1)
                break unless line
                if line.bytesize > MAX_RECORD_BYTES || !line.end_with?("\n")
                  protocol_failure(stdout, "Pi sent an oversized RPC record")
                  break
                end
                event = JSON.parse(line)
                unless event.is_a?(Hash)
                  protocol_failure(stdout, "Pi sent a non-object RPC record")
                  break
                end
                @mutex.synchronize { consume(event) if @stdout.equal?(stdout) }
              rescue JSON::ParserError
                protocol_failure(stdout, "Pi sent a malformed RPC record")
                break
              end
              unexpected_stop(stdout)
            rescue IOError, SystemCallError
              unexpected_stop(stdout)
            end

            def consume(event)
              if event["type"] == "response" && event["id"] == @startup_id
                data = event["data"]
                if event["success"] && data.is_a?(Hash) && data["sessionId"].is_a?(String) && !data["sessionId"].empty?
                  accept_state_unlocked(data)
                  if @reset_recovering
                    @task = nil
                    finish_reset_unlocked(:accepted)
                  else
                    @phase = "ready"
                  end
                else
                  unavailable_unlocked("Pi rejected its startup handshake")
                  finish_reset_unlocked(:unavailable) if @reset_recovering
                end
              elsif @phase == "resetting"
                consume_reset_unlocked(event)
              elsif @phase == "busy"
                if event["type"] == "response" && event["id"] == @task["command_id"] && event["success"] == false
                  finish_unlocked("failed", "Pi rejected the task")
                elsif event["type"] == "response" && event["id"] == @task["abort_command_id"] && event["success"] == false
                  finish_unlocked("failed", "Pi rejected cancellation")
                elsif event["type"] == "agent_start" && @task["status"] == "running"
                  @task["activity"] = "Pi is working"
                elsif event["type"] == "message_update" && event["assistantMessageEvent"].is_a?(Hash) &&
                    event["assistantMessageEvent"]["type"] == "text_delta" && event["assistantMessageEvent"]["delta"].is_a?(String)
                  append_output_unlocked(event["assistantMessageEvent"]["delta"])
                elsif event["type"] == "tool_execution_start" && event["toolName"].is_a?(String) && @task["status"] == "running"
                  @task["activity"] = "Running #{event["toolName"]}"
                elsif event["type"] == "agent_settled"
                  finish_unlocked(@task["status"] == "cancelling" ? "cancelled" : "completed", nil)
                end
              end
            end

            def append_output_unlocked(delta)
              output = (@task["output"] + delta).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
              truncated = false
              while output.bytesize > 32 * 1024
                output = output.each_char.drop(1).join
                truncated = true
              end
              @task["output"] = output
              @task["output_truncated"] ||= truncated
            end

            def consume_reset_unlocked(event)
              if event["type"] == "response" && event["id"] == @reset_command_id
                data = event["data"]
                if event["success"] && data.is_a?(Hash) && data["cancelled"] == true
                  @phase = "ready"
                  finish_reset_unlocked(:session_reset_rejected)
                elsif event["success"] && data.is_a?(Hash) && data["cancelled"] == false
                  @reset_state_id = "reset-state-#{SecureRandom.urlsafe_base64(18, false)}"
                  write(type: "get_state", id: @reset_state_id)
                else
                  recover_reset_unlocked
                end
              elsif event["type"] == "response" && event["id"] == @reset_state_id
                data = event["data"]
                if event["success"] && data.is_a?(Hash) && data["sessionId"].is_a?(String) && !data["sessionId"].empty? && data["sessionId"] != @pi_session_id
                  accept_state_unlocked(data)
                  @task = nil
                  @phase = "ready"
                  finish_reset_unlocked(:accepted)
                else
                  recover_reset_unlocked
                end
              end
            end

            def accept_state_unlocked(data)
              model = data["model"]
              @model = model.is_a?(Hash) ? [model["provider"], model["id"]].compact.join("/") : model
              @pi_session_id = data["sessionId"]
              @session_id = SecureRandom.urlsafe_base64(18, false)
              @error = nil
            end

            def timeout(id)
              @mutex.synchronize do
                return unless @phase == "busy" && @task["id"] == id
                finish_unlocked("failed", "Pi task exceeded the configured time limit")
                unavailable_unlocked("Pi is restarting")
              end
            end

            def protocol_failure(stdout, message)
              @mutex.synchronize do
                return unless @stdout.equal?(stdout)
                return recover_reset_unlocked if @phase == "resetting"

                finish_unlocked("failed", message) if @phase == "busy"
                unavailable_unlocked("Pi protocol failed")
              end
            end

            def unexpected_stop(stdout)
              @mutex.synchronize do
                return unless @stdout.equal?(stdout)
                return recover_reset_unlocked if @phase == "resetting"
                return if @phase == "unavailable"

                finish_unlocked("failed", "Pi stopped unexpectedly") if @phase == "busy"
                unavailable_unlocked("Pi stopped unexpectedly")
              end
            end

            def finish_unlocked(status, error)
              @task["status"] = status
              @task["activity"] = {"completed" => "Task completed", "cancelled" => "Task stopped"}.fetch(status, "Task failed")
              @task["error"] = error
              @task["finished_at"] = Time.now.utc.iso8601(6)
              @phase = "ready"
            end

            def recover_reset_unlocked
              if @reset_recovering
                unavailable_unlocked("Pi could not recover the session reset")
                finish_reset_unlocked(:unavailable)
                return
              end

              @reset_recovering = true
              @reset_command_id = nil
              @reset_state_id = nil
              stop_pi_unlocked
              @phase = "resetting"
              start_pi
            end

            def finish_reset_unlocked(result)
              @phase = "ready" if result == :accepted
              @reset_result = result
              @reset_recovering = false
              @reset_command_id = nil
              @reset_state_id = nil
              @reset_condition.broadcast
            end

            def stop_pi_unlocked
              stdin = @stdin
              wait_thread = @wait_thread
              @stdin = @stdout = @stderr = @wait_thread = nil
              stdin.close unless stdin.nil? || stdin.closed?
              Process.kill("TERM", wait_thread.pid) if wait_thread&.alive?
            rescue IOError, SystemCallError
              nil
            end

            def unavailable_unlocked(message)
              @phase = "unavailable"
              @error = message
            end

            def write(value)
              @write_mutex.synchronize do
                @stdin.write(JSON.generate(value) << "\n")
                @stdin.flush
              end
            end

            def snapshot_unlocked
              task = @task && @task.reject { |key, _| %w[command_id abort_command_id].include?(key) }
              {
                "contract_version" => 1,
                "session" => {"id" => @session_id, "status" => @phase, "model" => @model, "error" => @error},
                "task" => task && task.dup
              }
            end
          end

          class Server
            def initialize(identity:, executable:, task_timeout: 1_800, grace: 300)
              @identity = identity
              @executable = executable
              @task_timeout = task_timeout
              @grace = grace
              @token = SecureRandom.hex(24)
              @clients = 0
              @clients_mutex = Mutex.new
              @last_zero = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end

            def run
              owner = false
              File.open(@identity.lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
                return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)
                owner = true
                File.unlink(@identity.socket_path) if File.exist?(@identity.socket_path)
                @socket = UNIXServer.new(@identity.socket_path)
                File.chmod(0o600, @identity.socket_path)
                @runtime = Runtime.new(project_root: @identity.project_root, executable: @executable, task_timeout: @task_timeout)
                publish_metadata
                accept_loop
              ensure
                if owner
                  @socket.close if @socket && !@socket.closed?
                  @runtime.close if @runtime
                  File.unlink(@identity.socket_path) if File.exist?(@identity.socket_path)
                  File.unlink(@identity.metadata_path) if File.exist?(@identity.metadata_path)
                end
              end
              true
            end

            private

            def publish_metadata
              metadata = {
                "protocol" => PROTOCOL_VERSION, "identity" => @identity.identity, "token" => @token,
                "socket" => @identity.socket_path, "pid" => Process.pid
              }
              temporary = "#{@identity.metadata_path}.#{Process.pid}.tmp"
              File.open(temporary, "w", 0o600) do |file|
                file.write(JSON.generate(metadata))
                file.flush
                file.fsync
              end
              File.rename(temporary, @identity.metadata_path)
              File.chmod(0o600, @identity.metadata_path)
            ensure
              File.unlink(temporary) if temporary && File.exist?(temporary)
            end

            def accept_loop
              loop do
                ready = IO.select([@socket], nil, nil, 0.1)
                Thread.new(@socket.accept) { |client| serve(client) } if ready
                break if expired?
              end
            end

            def expired?
              @clients_mutex.synchronize do
                @clients.zero? && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_zero >= @grace
              end
            end

            def serve(client)
              @clients_mutex.synchronize { @clients += 1 }
              handshake = read_record(client)
              unless handshake == {"type" => "handshake", "protocol" => PROTOCOL_VERSION, "identity" => @identity.identity, "token" => @token}
                return write_record(client, "type" => "error", "code" => "incompatible")
              end
              write_record(client, "type" => "handshake", "protocol" => PROTOCOL_VERSION, "identity" => @identity.identity, "token" => @token)
              while (command = read_record(client))
                if command_shape?(command, "state", %w[id type])
                  write_record(client, "id" => command["id"], "ok" => true, "snapshot" => @runtime.snapshot)
                elsif command_shape?(command, "submit", %w[id task type])
                  result, value = @runtime.submit(command["task"])
                  write_record(client, "id" => command["id"], "ok" => result == :accepted, "result" => result.to_s, result == :invalid ? "message" : "snapshot" => value)
                elsif command_shape?(command, "cancel", %w[id task_id type]) && command["task_id"].is_a?(String)
                  result, snapshot = @runtime.cancel(command["task_id"])
                  write_record(client, "id" => command["id"], "ok" => %i[accepted cancelled].include?(result), "result" => result.to_s, "snapshot" => snapshot)
                elsif command_shape?(command, "reset", %w[id type])
                  result, snapshot = @runtime.reset
                  write_record(client, "id" => command["id"], "ok" => result == :accepted, "result" => result.to_s, "snapshot" => snapshot)
                else
                  id = command["id"] if command.is_a?(Hash) && command["id"].is_a?(String)
                  known = command.is_a?(Hash) && %w[state submit cancel reset].include?(command["type"])
                  write_record(client, "id" => id, "ok" => false, "result" => "invalid", "message" => known ? "malformed broker command" : "unknown broker command")
                end
              end
            rescue JSON::ParserError, IOError, SystemCallError, Unavailable
              nil
            ensure
              client.close rescue nil
              @clients_mutex.synchronize do
                @clients -= 1
                @last_zero = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @clients.zero?
              end
            end

            def command_shape?(command, type, keys)
              command.is_a?(Hash) && command.keys.sort == keys && command["type"] == type &&
                command["id"].is_a?(String) && command["id"].match?(/\A[0-9a-f]{24}\z/)
            end

            def read_record(io)
              line = io.gets("\n", MAX_RECORD_BYTES + 1)
              return nil unless line
              raise Unavailable, "oversized broker record" if line.bytesize > MAX_RECORD_BYTES || !line.end_with?("\n")
              JSON.parse(line)
            end

            def write_record(io, value)
              io.write(JSON.generate(value) << "\n")
              io.flush
            end
          end

          class Client
            def initialize(project_root:, executable: "pi", task_timeout: 1_800, runtime_root: nil)
              @identity = Identity.new(project_root, runtime_root: runtime_root)
              @executable = executable
              @task_timeout = task_timeout
              @mutex = Mutex.new
              @pid = Process.pid
            end

            attr_reader :identity

            def snapshot
              request("type" => "state")
            end

            def submit(task)
              request("type" => "submit", "task" => task)
            end

            def cancel(task_id)
              request("type" => "cancel", "task_id" => task_id)
            end

            def reset
              request("type" => "reset")
            end

            def close
              @mutex.synchronize do
                @socket.close if @socket && !@socket.closed?
                @socket = nil
              end
            rescue IOError, SystemCallError
              @socket = nil
            end

            private

            def request(command)
              @mutex.synchronize do
                reset_after_fork
                connect unless @socket
                command = command.merge("id" => SecureRandom.hex(12))
                write_record(command)
                response = read_record
                raise Unavailable, "broker response was not correlated" unless response["id"] == command["id"]
                response
              rescue Unavailable
                discard_socket
                raise
              rescue JSON::ParserError, IOError, SystemCallError => error
                discard_socket
                raise Unavailable, "broker is unavailable: #{error.message}"
              end
            end

            def reset_after_fork
              return if @pid == Process.pid
              discard_socket
              @pid = Process.pid
            end

            def discard_socket
              @socket.close if @socket && !@socket.closed?
            rescue IOError, SystemCallError
              nil
            ensure
              @socket = nil
            end

            def connect
              metadata = load_metadata
              if metadata
                result = connect_metadata(metadata)
                return if result == :connected
                raise Unavailable, "broker identity handshake failed" if result == :incompatible
              end
              launch
              100.times do
                sleep 0.02
                metadata = load_metadata
                next unless metadata
                result = connect_metadata(metadata)
                return if result == :connected
                raise Unavailable, "broker identity handshake failed" if result == :incompatible
              end
              raise Unavailable, "broker did not become available"
            end

            def load_metadata
              JSON.parse(File.read(@identity.metadata_path))
            rescue Errno::ENOENT, JSON::ParserError
              nil
            end

            def connect_metadata(metadata)
              required = metadata["protocol"] == PROTOCOL_VERSION && metadata["identity"] == @identity.identity &&
                metadata["socket"] == @identity.socket_path && metadata["token"].is_a?(String)
              return :incompatible unless required
              socket = UNIXSocket.new(metadata["socket"])
              socket.write(JSON.generate("type" => "handshake", "protocol" => PROTOCOL_VERSION, "identity" => @identity.identity, "token" => metadata["token"]) << "\n")
              socket.flush
              response = JSON.parse(socket.gets("\n", MAX_RECORD_BYTES + 1) || "")
              unless response == {"type" => "handshake", "protocol" => PROTOCOL_VERSION, "identity" => @identity.identity, "token" => metadata["token"]}
                socket.close
                return :incompatible
              end
              @socket = socket
              :connected
            rescue Errno::ENOENT, Errno::ECONNREFUSED, IOError, JSON::ParserError
              begin
                socket.close if socket && !socket.closed?
              rescue IOError, SystemCallError
                nil
              end
              :missing
            end

            def launch
              env = {
                "PI_BROWSER_TASKBAR_PROJECT_ROOT" => @identity.project_root,
                "PI_BROWSER_TASKBAR_EXECUTABLE" => @executable,
                "PI_BROWSER_TASKBAR_TASK_TIMEOUT" => @task_timeout.to_s
              }
              launcher = File.expand_path("broker_launcher.rb", __dir__)
              pid = Process.spawn(env, RbConfig.ruby, launcher, out: File::NULL, err: File::NULL, close_others: true)
              Process.detach(pid)
            rescue SystemCallError => error
              raise Unavailable, "broker could not be launched: #{error.message}"
            end

            def write_record(value)
              @socket.write(JSON.generate(value) << "\n")
              @socket.flush
            end

            def read_record
              line = @socket.gets("\n", MAX_RECORD_BYTES + 1)
              raise Unavailable, "broker closed its connection" unless line && line.end_with?("\n") && line.bytesize <= MAX_RECORD_BYTES
              JSON.parse(line)
            end
          end
        end
      end
    end
  end
end
