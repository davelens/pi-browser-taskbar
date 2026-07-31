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
          MAX_OUTPUT_BYTES = 32 * 1024
          DIALOG_METHODS = %w[select confirm input editor].freeze
          DEFAULT_ABORT_TIMEOUT = 5
          DEFAULT_TERMINATION_TIMEOUT = 1
          DEFAULT_RESTART_ATTEMPTS = 3
          DEFAULT_RESTART_DELAY = 0.1

          class Unavailable < StandardError; end

          class Identity
            attr_reader :project_root, :uid, :key, :directory, :runtime_root

            def initialize(project_root, runtime_root: nil)
              @project_root = File.realpath(project_root)
              @uid = Process.uid
              @key = Digest::SHA256.hexdigest("#{uid}\0#{@project_root}")[0, 32]
              @runtime_root = runtime_root || default_runtime_root
              secure_directory(@runtime_root)
              @directory = File.join(@runtime_root, key)
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
            def initialize(project_root:, executable:, task_timeout: 1_800,
              abort_timeout: DEFAULT_ABORT_TIMEOUT,
              termination_timeout: DEFAULT_TERMINATION_TIMEOUT,
              max_restart_attempts: DEFAULT_RESTART_ATTEMPTS,
              restart_delay: DEFAULT_RESTART_DELAY)
              @project_root = project_root
              @executable = executable
              @task_timeout = task_timeout
              @abort_timeout = abort_timeout
              @termination_timeout = termination_timeout
              @max_restart_attempts = max_restart_attempts
              @restart_delay = restart_delay
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
              @restart_attempts = 0
              @closed = false
              start_pi
            end

            def snapshot
              @mutex.synchronize { snapshot_unlocked }
            end

            def work_active?
              @mutex.synchronize { %w[starting busy resetting].include?(@phase) }
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
                  "started_at" => now, "finished_at" => nil, "command_id" => "task-#{id}",
                  "prompt_accepted" => false, "pending_error" => nil
                }
                @phase = "busy"
                write(type: "prompt", id: @task["command_id"], message: task.pi_prompt)
                Thread.new do
                  sleep @task_timeout
                  timeout(id)
                end
                [:accepted, snapshot_unlocked]
              rescue IOError, SystemCallError
                restart_after_protocol_failure_unlocked(
                  "Pi stopped unexpectedly", "Pi became unavailable before accepting the task"
                )
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
                  Thread.new do
                    sleep @abort_timeout
                    abort_timeout(id)
                  end
                  [:accepted, snapshot_unlocked]
                when "cancelling"
                  [:accepted, snapshot_unlocked]
                when "cancelled"
                  [:cancelled, snapshot_unlocked]
                else
                  [:not_cancellable, snapshot_unlocked]
                end
              rescue IOError, SystemCallError
                restart_after_protocol_failure_unlocked(
                  "Pi stopped unexpectedly", "Pi became unavailable before accepting cancellation"
                )
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
                @reset_condition.wait(@mutex) while @reset_result.nil?
                [@reset_result, snapshot_unlocked]
              end
            end

            def close
              @mutex.synchronize do
                @closed = true
                stop_pi_unlocked
              end
            rescue IOError, SystemCallError
              nil
            end

            private

            def start_pi
              return if @closed

              @restart_attempts += 1
              @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
                @executable, "--mode", "rpc", chdir: @project_root, pgroup: true
              )
              stdout = @stdout
              stderr = @stderr
              @stderr_reader = Thread.new { drain_stderr(stderr) }
              @startup_id = "startup-#{SecureRandom.urlsafe_base64(18, false)}"
              write(type: "get_state", id: @startup_id)
              @reader = Thread.new { read_events(stdout) }
            rescue IOError, SystemCallError
              retry_startup_unlocked("Pi executable was not found or could not be started")
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
                if line.bytesize > MAX_RECORD_BYTES
                  protocol_failure(stdout, "Pi sent an oversized RPC record")
                  break
                elsif !line.end_with?("\n")
                  protocol_failure(stdout, "Pi sent an unterminated RPC record")
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
              return consume_extension_request_unlocked(event) if event["type"] == "extension_ui_request"

              if event["type"] == "response" && event["id"] == @startup_id
                data = event["data"]
                if event["success"] == true && valid_state?(data)
                  accept_state_unlocked(data)
                  if @reset_recovering
                    @task = nil
                    finish_reset_unlocked(:accepted)
                  else
                    @phase = "ready"
                  end
                else
                  retry_startup_unlocked(event["success"] == false ? "Pi rejected its startup handshake" : "Pi returned invalid startup state")
                end
              elsif event["type"] == "response" && @phase == "starting"
                retry_startup_unlocked("Pi returned an unexpected RPC response")
              elsif @phase == "resetting"
                consume_reset_unlocked(event)
              elsif @phase == "busy"
                consume_busy_unlocked(event)
              elsif event["type"] == "response"
                restart_after_protocol_failure_unlocked("Pi returned an unexpected RPC response")
              end
            end

            def consume_busy_unlocked(event)
              if event["type"] == "response"
                consume_task_response_unlocked(event)
              elsif event["type"] == "agent_start" && running?
                @task["activity"] = "Pi is working"
              elsif event["type"] == "agent_end" && running?
                @task["activity"] = "Pi finished a turn"
              elsif event["type"] == "message_update"
                consume_message_update_unlocked(event)
              elsif event["type"] == "tool_execution_start" && running?
                @task["activity"] = "Running #{safe_label(event["toolName"], "a tool")}"
              elsif event["type"] == "tool_execution_update" && running?
                @task["activity"] = "Running #{safe_label(event["toolName"], "a tool")}"
              elsif event["type"] == "tool_execution_end" && running?
                prefix = event["isError"] == true ? "Tool failed" : "Finished"
                @task["activity"] = "#{prefix} #{safe_label(event["toolName"], "a tool")}"
              elsif event["type"] == "compaction_start" && running?
                @task["activity"] = "Compacting conversation"
              elsif event["type"] == "compaction_end" && running?
                if event["errorMessage"].is_a?(String) && !event["errorMessage"].empty?
                  mark_pending_failure_unlocked("Pi could not compact the conversation")
                else
                  @task["activity"] = event["willRetry"] == true ? "Retrying after compaction" : "Conversation compacted"
                end
              elsif event["type"] == "auto_retry_start" && running?
                attempt = event["attempt"]
                maximum = event["maxAttempts"]
                @task["activity"] = if attempt.is_a?(Integer) && attempt.between?(1, 999) && maximum.is_a?(Integer) && maximum.between?(1, 999)
                  "Retrying request (#{attempt}/#{maximum})"
                else
                  "Retrying request"
                end
              elsif event["type"] == "auto_retry_end" && running?
                event["success"] == false ? mark_pending_failure_unlocked("Pi could not complete the task after retries") : @task["activity"] = "Pi is working"
              elsif event["type"] == "agent_settled"
                if @task["status"] == "cancelling"
                  finish_unlocked("cancelled", nil)
                elsif @task["pending_error"]
                  finish_unlocked("failed", @task["pending_error"])
                else
                  finish_unlocked("completed", nil)
                end
              end
            end

            def consume_task_response_unlocked(event)
              if event["id"] == @task["command_id"] && !@task["prompt_accepted"]
                if event["success"] == true
                  @task["prompt_accepted"] = true
                  @task["activity"] = "Pi accepted the task"
                elsif event["success"] == false
                  finish_unlocked("failed", "Pi rejected the task")
                else
                  restart_after_protocol_failure_unlocked("Pi returned an unexpected RPC response")
                end
              elsif event["id"] == @task["abort_command_id"] && @task["abort_command_id"]
                if event["success"] == false
                  restart_after_protocol_failure_unlocked("Pi rejected cancellation")
                elsif event["success"] != true
                  restart_after_protocol_failure_unlocked("Pi returned an unexpected RPC response")
                end
              else
                restart_after_protocol_failure_unlocked("Pi returned an unexpected RPC response")
              end
            end

            def consume_message_update_unlocked(event)
              update = event["assistantMessageEvent"]
              return unless update.is_a?(Hash)

              if update["type"] == "text_delta"
                return restart_after_protocol_failure_unlocked("Pi sent a malformed RPC event") unless update["delta"].is_a?(String)
                append_output_unlocked(update["delta"])
              elsif update["type"] == "error" && running?
                mark_pending_failure_unlocked("Pi reported a message error")
              end
            end

            def consume_extension_request_unlocked(event)
              return unless DIALOG_METHODS.include?(event["method"])
              return restart_after_protocol_failure_unlocked("Pi sent a malformed RPC event") unless event["id"].is_a?(String) && !event["id"].empty?

              write(type: "extension_ui_response", id: event["id"], cancelled: true)
            rescue IOError, SystemCallError
              restart_after_protocol_failure_unlocked("Pi protocol failed")
            end

            def append_output_unlocked(delta)
              output = (@task["output"] + delta).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
              if output.bytesize > MAX_OUTPUT_BYTES
                output = output.byteslice(-MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES)
                output = output.byteslice(1..) until output.valid_encoding?
                @task["output_truncated"] = true
              end
              @task["output"] = output
            end

            def mark_pending_failure_unlocked(message)
              @task["pending_error"] = message
              @task["activity"] = "Task failed"
            end

            def running?
              @task["status"] == "running"
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
                if event["success"] && valid_state?(data) && data["sessionId"] != @pi_session_id
                  accept_state_unlocked(data)
                  @task = nil
                  @phase = "ready"
                  finish_reset_unlocked(:accepted)
                else
                  recover_reset_unlocked
                end
              elsif event["type"] == "response"
                recover_reset_unlocked
              end
            end

            def accept_state_unlocked(data)
              @model = model_name(data["model"])
              @pi_session_id = data["sessionId"]
              @session_id = SecureRandom.urlsafe_base64(18, false)
              @error = nil
              @restart_attempts = 0
            end

            def timeout(id)
              @mutex.synchronize do
                return unless @phase == "busy" && @task["id"] == id && @task["status"] == "running"
                restart_after_protocol_failure_unlocked("Pi task exceeded the configured time limit", "Pi is restarting")
              end
            end

            def abort_timeout(id)
              @mutex.synchronize do
                return unless @phase == "busy" && @task["id"] == id && @task["status"] == "cancelling"
                finish_unlocked("cancelled", "Pi did not stop before the cancellation deadline")
                replace_pi_unlocked("Pi is restarting")
              end
            end

            def protocol_failure(stdout, message)
              @mutex.synchronize do
                return unless @stdout.equal?(stdout)
                return recover_reset_unlocked if @phase == "resetting"

                if %w[busy ready].include?(@phase)
                  restart_after_protocol_failure_unlocked(message)
                else
                  retry_startup_unlocked("Pi protocol failed")
                end
              end
            end

            def unexpected_stop(stdout)
              @mutex.synchronize do
                return unless @stdout.equal?(stdout)
                return recover_reset_unlocked if @phase == "resetting"
                return if @phase == "unavailable"

                if %w[busy ready].include?(@phase)
                  restart_after_protocol_failure_unlocked("Pi stopped unexpectedly", "Pi stopped unexpectedly")
                else
                  retry_startup_unlocked("Pi stopped during startup")
                end
              end
            end

            def restart_after_protocol_failure_unlocked(task_message, session_message = "Pi protocol failed")
              finish_unlocked("failed", task_message) if @phase == "busy"
              replace_pi_unlocked(session_message)
            end

            def replace_pi_unlocked(message)
              stop_pi_unlocked
              @session_id = @pi_session_id = @model = nil
              @phase = "starting"
              @error = message
              @restart_attempts = 0
              start_pi
            end

            def retry_startup_unlocked(message)
              stop_pi_unlocked
              if @restart_attempts < @max_restart_attempts && !@closed
                @phase = "starting"
                @error = message
                Thread.new do
                  sleep @restart_delay
                  @mutex.synchronize { start_pi if @phase == "starting" && !@wait_thread }
                end
              else
                unavailable_unlocked("Pi could not be restarted")
                finish_reset_unlocked(:unavailable) if @reset_recovering
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
              @session_id = @pi_session_id = @model = nil
              @restart_attempts = 0
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
              return unless wait_thread

              signal_process_group("TERM", wait_thread.pid)
              wait_for_process_group(wait_thread.pid, @termination_timeout)
              signal_process_group("KILL", wait_thread.pid) if process_group_alive?(wait_thread.pid)
              wait_for_process_group(wait_thread.pid, @termination_timeout)
              wait_thread.join(@termination_timeout)
            rescue IOError, SystemCallError
              nil
            end

            def signal_process_group(signal, pid)
              Process.kill(signal, -pid)
            rescue Errno::ESRCH
              nil
            end

            def wait_for_process_group(pid, timeout)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
              while process_group_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
                sleep 0.01
              end
            end

            def process_group_alive?(pid)
              Process.kill(0, -pid)
              true
            rescue Errno::ESRCH
              false
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

            def valid_state?(data)
              data.is_a?(Hash) && data["sessionId"].is_a?(String) && !data["sessionId"].empty? && !model_name(data["model"]).nil?
            end

            def model_name(model)
              value = if model.is_a?(Hash) && model["provider"].is_a?(String) && model["id"].is_a?(String)
                "#{model["provider"]}/#{model["id"]}"
              elsif model.is_a?(String)
                model
              end
              safe_label(value, nil, 256)
            end

            def safe_label(value, fallback, max_bytes = 100)
              return fallback unless value.is_a?(String)

              value = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                .gsub(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/, " ").strip.gsub(/\s+/, " ")
              return fallback if value.empty?
              return value if value.bytesize <= max_bytes

              value = value.byteslice(0, max_bytes)
              value = value.byteslice(0...-1) until value.valid_encoding?
              value
            end

            def snapshot_unlocked
              task = @task && @task.reject { |key, _| %w[command_id abort_command_id prompt_accepted pending_error].include?(key) }
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
              @idle_since = nil
              @stopping = false
            end

            def stop
              @stopping = true
            end

            def run
              owner = false
              File.open(@identity.lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
                return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)
                owner = true
                unlink_if_present(@identity.socket_path)
                @socket = UNIXServer.new(@identity.socket_path)
                File.chmod(0o600, @identity.socket_path)
                @runtime = Runtime.new(project_root: @identity.project_root, executable: @executable, task_timeout: @task_timeout)
                publish_metadata
                accept_loop
              ensure
                if owner
                  @socket.close if @socket && !@socket.closed?
                  @runtime.close if @runtime
                  unlink_if_present(@identity.socket_path)
                  unlink_if_present(@identity.metadata_path)
                end
              end
              true
            end

            private

            def unlink_if_present(path)
              File.unlink(path)
            rescue Errno::ENOENT
              nil
            end

            def publish_metadata
              metadata = {
                "protocol" => PROTOCOL_VERSION, "identity" => @identity.identity, "token" => @token,
                "socket" => @identity.socket_path, "pid" => Process.pid
              }
              temporary = "#{@identity.metadata_path}.#{Process.pid}.#{@token}.tmp"
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
                if ready
                  client = @socket.accept
                  @clients_mutex.synchronize do
                    @clients += 1
                    @idle_since = nil
                  end
                  Thread.new(client) { |connection| serve(connection) }
                end
                break if @stopping || expired?
              end
            end

            def expired?
              active = @runtime.work_active?
              @clients_mutex.synchronize do
                if @clients.positive? || active
                  @idle_since = nil
                  false
                else
                  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                  @idle_since ||= now
                  now - @idle_since >= @grace
                end
              end
            end

            def serve(client)
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
                @idle_since = nil if @clients.zero?
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
            CONNECT_ATTEMPTS = 100
            CONNECT_DELAY = 0.02

            def initialize(project_root:, executable: "pi", task_timeout: 1_800, runtime_root: nil)
              @identity = Identity.new(project_root, runtime_root: runtime_root)
              @executable = executable
              @task_timeout = task_timeout
              @runtime_root = runtime_root
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
              reset_after_fork
              @mutex.synchronize { discard_socket }
            rescue IOError, SystemCallError
              @socket = nil
            end

            private

            def request(command)
              reset_after_fork
              @mutex.synchronize do
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

              inherited = @socket
              @socket = nil
              @mutex = Mutex.new
              @pid = Process.pid
              inherited.close if inherited && !inherited.closed?
            rescue IOError, SystemCallError
              nil
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
              return if metadata && connect_metadata(metadata) == :connected

              launch
              CONNECT_ATTEMPTS.times do
                sleep CONNECT_DELAY
                metadata = load_metadata
                next unless metadata
                return if connect_metadata(metadata) == :connected
              end
              raise Unavailable, "broker did not become available with a verified identity"
            end

            def load_metadata
              stat = File.lstat(@identity.metadata_path)
              return nil unless stat.file? && !stat.symlink? && stat.uid == @identity.uid && (stat.mode & 0o077).zero? && stat.size <= MAX_RECORD_BYTES

              flags = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
              File.open(@identity.metadata_path, flags) do |file|
                opened = file.stat
                return nil unless opened.dev == stat.dev && opened.ino == stat.ino
                JSON.parse(file.read(MAX_RECORD_BYTES + 1))
              end
            rescue SystemCallError, JSON::ParserError
              nil
            end

            def connect_metadata(metadata)
              required = metadata.is_a?(Hash) && metadata.keys.sort == %w[identity pid protocol socket token] &&
                metadata["protocol"] == PROTOCOL_VERSION && metadata["identity"] == @identity.identity &&
                metadata["socket"] == @identity.socket_path && metadata["token"].is_a?(String) &&
                metadata["token"].match?(/\A[0-9a-f]{48}\z/) && metadata["pid"].is_a?(Integer) && metadata["pid"].positive?
              return :incompatible unless required
              socket_stat = File.lstat(metadata["socket"])
              return :incompatible unless socket_stat.socket? && socket_stat.uid == @identity.uid && (socket_stat.mode & 0o077).zero?

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
            rescue SystemCallError, IOError, JSON::ParserError
              begin
                socket.close if socket && !socket.closed?
              rescue IOError, SystemCallError
                nil
              end
              :missing
            end

            def launch
              env = {
                "PI_BROWSER_TASKBAR_BROKER_PROJECT_ROOT" => @identity.project_root,
                "PI_BROWSER_TASKBAR_BROKER_EXECUTABLE" => @executable,
                "PI_BROWSER_TASKBAR_BROKER_TASK_TIMEOUT" => @task_timeout.to_s,
                "PI_BROWSER_TASKBAR_BROKER_RUNTIME_ROOT" => @runtime_root
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
