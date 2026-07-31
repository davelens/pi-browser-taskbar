# frozen_string_literal: true

require "action_controller/railtie"
require "action_view/railtie"
require "rails/engine"
require "ipaddr"
require_relative "broker"

module Pi
  module Browser
    module Taskbar
      module Rails
        class Engine < ::Rails::Engine
          isolate_namespace Pi::Browser::Taskbar::Rails
          config.paths["config/routes.rb"] = File.expand_path("routes.rb", __dir__)

          initializer "pi_browser_taskbar.filter_browser_context",
            after: "pi_browser_taskbar.enable_erb_annotations" do |app|
            next unless Pi::Browser::Taskbar::Rails.active?

            app.config.filter_parameters += %i[prompt context]
          end

          initializer "pi_browser_taskbar.enable_erb_annotations",
            after: :load_config_initializers do |app|
            next unless ::Rails.env.development?

            Pi::Browser::Taskbar::Rails.finalize_configuration!(default_project_root: app.root.to_s)
            next unless Pi::Browser::Taskbar::Rails.active?

            app.config.action_view.annotate_rendered_view_with_filenames = true
            ActionView::Base.annotate_rendered_view_with_filenames = true
            ActionView::Base.include(Pi::Browser::Taskbar::Rails::LayoutHelper) unless ActionView::Base < Pi::Browser::Taskbar::Rails::LayoutHelper
          end

          config.after_initialize do |_app|
            next unless Pi::Browser::Taskbar::Rails.active?
            next if ActionView::Base.annotate_rendered_view_with_filenames

            raise "Pi Browser Taskbar requires config.action_view.annotate_rendered_view_with_filenames = true"
          end
        end

        class ApplicationController < ActionController::Base
          protect_from_forgery with: :exception
          before_action :require_taskbar_access, prepend: true

          rescue_from ActionController::InvalidAuthenticityToken do
            response.set_header("Cache-Control", "no-store")
            render json: {error: {code: "invalid_csrf", message: "The session CSRF token is invalid"}}, status: :unprocessable_entity
          end

          private

          def require_taskbar_access
            response.set_header("Cache-Control", "no-store")
            host = request.host.to_s.downcase.sub(/\.+\z/, "")
            host = host[1...-1] if host.start_with?("[") && host.end_with?("]")
            unless host.match?(/[%\/\[\]]/)
              begin
                host = IPAddr.new(host).to_s
              rescue IPAddr::InvalidAddressError
                nil
              end
            end
            allowed_hosts = Pi::Browser::Taskbar::Rails.allowed_hosts
            loopback = IPAddr.new(request.remote_ip).loopback?
            local_name = host == "localhost" || (host.end_with?(".localhost") && host.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/))
            local_host = local_name || host == "127.0.0.1" || host == "::1"
            return if (loopback && (local_host || allowed_hosts.include?(host))) || (!loopback && !allowed_hosts.empty? && allowed_hosts.include?(host))

            render json: {error: {code: "forbidden", message: "Pi Browser Taskbar is not allowed from this host or client address"}}, status: :forbidden
          rescue IPAddr::InvalidAddressError
            render json: {error: {code: "forbidden", message: "Pi Browser Taskbar is not allowed from this host or client address"}}, status: :forbidden
          end
        end

        class ApiController < ApplicationController
          MAX_BODY_BYTES = 128 * 1024

          def state
            response = Pi::Browser::Taskbar::Rails.broker_client.snapshot
            render_snapshot(response.fetch("snapshot"), :ok)
          rescue Broker::Unavailable
            render_unavailable
          end

          def tasks
            body = request.raw_post
            return render_error(:payload_too_large, "oversized_payload", "Request body exceeds 128 KiB") if body.bytesize > MAX_BODY_BYTES
            task = JSON.parse(body)
            raise JSON::ParserError, "object required" unless task.is_a?(Hash)
            validated = Task.parse(task)
            response = Pi::Browser::Taskbar::Rails.broker_client.submit("prompt" => validated.prompt, "context" => validated.context)
            case response["result"]
            when "accepted"
              render_snapshot(response.fetch("snapshot"), :accepted)
            when "busy"
              render_error(:conflict, "busy", "Another Pi task is active", response["snapshot"])
            when "unavailable"
              render_error(:service_unavailable, "unavailable", "Pi is not ready", response["snapshot"])
            when "invalid"
              render_error(:unprocessable_entity, "invalid_task", "Task request is invalid")
            else
              render_unavailable
            end
          rescue JSON::ParserError
            render_error(:bad_request, "malformed_json", "Request body must be valid JSON")
          rescue Task::Invalid
            render_error(:unprocessable_entity, "invalid_task", "Task request is invalid")
          rescue Broker::Unavailable
            render_unavailable
          end

          def reset_session
            response = Pi::Browser::Taskbar::Rails.broker_client.reset
            case response["result"]
            when "accepted"
              render_snapshot(response.fetch("snapshot"), :accepted)
            when "reset_while_busy"
              render_error(:conflict, "reset_while_busy", "A fresh session cannot start while Pi is busy", response["snapshot"])
            when "session_reset_rejected"
              render_error(:conflict, "session_reset_rejected", "Pi kept the current session", response["snapshot"])
            when "unavailable"
              render_error(:service_unavailable, "unavailable", "Pi is not ready", response["snapshot"])
            else
              render_unavailable
            end
          rescue Broker::Unavailable
            render_unavailable
          end

          def cancel_task
            response = Pi::Browser::Taskbar::Rails.broker_client.cancel(params[:id])
            case response["result"]
            when "accepted"
              render_snapshot(response.fetch("snapshot"), :accepted)
            when "cancelled"
              render_snapshot(response.fetch("snapshot"), :ok)
            when "not_found"
              render_error(:not_found, "task_not_found", "Task was not found", response["snapshot"])
            when "not_cancellable"
              render_error(:conflict, "task_not_cancellable", "Task can no longer be stopped", response["snapshot"])
            when "unavailable"
              render_error(:service_unavailable, "unavailable", "Pi is not ready", response["snapshot"])
            else
              render_unavailable
            end
          rescue Broker::Unavailable
            render_unavailable
          end

          private

          def render_snapshot(snapshot, status)
            response.set_header("Cache-Control", "no-store")
            render json: snapshot, status: status
          end

          def render_error(status, code, message, snapshot = nil)
            response.set_header("Cache-Control", "no-store")
            payload = {error: {code: code, message: message}}
            payload[:snapshot] = snapshot if snapshot
            render json: payload, status: status
          end

          def render_unavailable
            snapshot = {"contract_version" => 1, "session" => {"id" => nil, "status" => "unavailable", "model" => nil, "error" => "Project broker is unavailable"}, "task" => nil}
            render_error(:service_unavailable, "unavailable", "Pi is not ready", snapshot)
          end
        end

        class AssetsController < ApplicationController
          skip_forgery_protection
          skip_after_action :verify_same_origin_request

          def show
            filename = params[:filename]
            path = File.join(__dir__, "assets", filename)
            return head :not_found unless %w[pi_browser_taskbar.js pi_browser_taskbar.css].include?(filename) && File.file?(path)

            response.set_header("Cache-Control", "no-store")
            send_data File.binread(path), disposition: "inline", type: filename.end_with?(".js") ? "text/javascript" : "text/css"
          end

          private

          # Package scripts are intentionally served for ordinary same-origin <script> tags.
          def verify_same_origin_request
          end
        end
      end
    end
  end
end
