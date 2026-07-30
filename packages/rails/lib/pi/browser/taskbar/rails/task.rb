# frozen_string_literal: true

require "json"
require "uri"
require "unicode_normalize/normalize" if RUBY_VERSION < "3.0"

module Pi
  module Browser
    module Taskbar
      module Rails
        class Task
          MAX_REQUEST_BYTES = 128 * 1024
          MAX_CONTEXT_BYTES = 96 * 1024
          MAX_SNAPSHOT_BYTES = 48 * 1024
          MAX_SNAPSHOT_NODES = 750
          FIELDS = %w[context prompt].freeze
          CONTEXT_FIELDS = %w[contract_version focus_points location route snapshot truncation].freeze
          NODE_FIELDS = %w[children classes id name role tag text].freeze

          class Invalid < StandardError; end

          attr_reader :prompt, :context

          def self.parse(value)
            new(value).tap(&:validate!)
          end

          def initialize(value)
            @value = value
          end

          def validate!
            object!(@value, "task")
            size!(@value, MAX_REQUEST_BYTES, "request is too large")
            exact!(@value, FIELDS, "task")
            @prompt = normalize_prompt(@value["prompt"])
            @context = @value["context"]
            validate_context!
            self
          end

          def pi_prompt
            "#{prompt}\n\n--- BEGIN UNTRUSTED BROWSER CONTEXT ---\n#{safe_json(context)}\n--- END UNTRUSTED BROWSER CONTEXT ---"
          end

          private

          def validate_context!
            object!(context, "context")
            size!(context, MAX_CONTEXT_BYTES, "context is too large")
            exact!(context, CONTEXT_FIELDS, "context")
            invalid!("contract_version must be 1") unless context["contract_version"] == 1
            validate_location!(context["location"])
            validate_route!(context["route"])
            count = validate_node!(context["snapshot"], "snapshot", 0)
            invalid!("snapshot must contain at most 750 nodes") if count > MAX_SNAPSHOT_NODES
            size!(context["snapshot"], MAX_SNAPSHOT_BYTES, "snapshot is too large")
            validate_focus!(context["focus_points"])
            validate_truncation!(context["truncation"])
          end

          def validate_location!(location)
            object!(location, "location")
            exact!(location, %w[origin path query_names], "location")
            string!(location["origin"], "location.origin", 512)
            uri = URI.parse(location["origin"])
            unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment && [nil, ""].include?(uri.path)
              invalid!("location.origin must be an HTTP(S) origin without credentials or path")
            end
            string!(location["path"], "location.path", 2_048)
            invalid!("location.path is invalid") unless location["path"].start_with?("/")
            strings!(location["query_names"], "location.query_names", 32, 128)
          rescue URI::InvalidURIError
            invalid!("location.origin must be an HTTP(S) origin without credentials or path")
          end

          def validate_route!(route)
            return if route.nil?
            object!(route, "route")
            exact!(route, %w[action handler method pattern], "route")
            string!(route["method"], "route.method", 16)
            invalid!("route.method is invalid") unless route["method"].match?(/\A[A-Z]+\z/)
            string!(route["pattern"], "route.pattern", 1_000)
            string!(route["handler"], "route.handler", 500)
            optional_string!(route["action"], "route.action", 256)
          end

          def validate_node!(node, label, depth)
            object!(node, label)
            invalid!("#{label} exceeds maximum depth") if depth > 12
            fields!(node, NODE_FIELDS, %w[children tag], label)
            string!(node["tag"], "#{label}.tag", 64)
            invalid!("#{label}.tag is invalid") unless node["tag"].match?(/\A[a-z][a-z0-9-]*\z/)
            optional_string!(node["role"], "#{label}.role", 64)
            optional_string!(node["name"], "#{label}.name", 512)
            optional_string!(node["text"], "#{label}.text", 1_000)
            optional_string!(node["id"], "#{label}.id", 256)
            strings!(node["classes"], "#{label}.classes", 32, 128) unless node["classes"].nil?
            invalid!("#{label}.children must be an array") unless node["children"].is_a?(Array)
            1 + node["children"].each_with_index.sum { |child, index| validate_node!(child, "#{label}.children[#{index}]", depth + 1) }
          end

          def validate_focus!(points)
            invalid!("focus_points must contain at most 8 items") unless points.is_a?(Array) && points.length <= 8
            points.each_with_index do |point, index|
              label = "focus_points[#{index}]"
              object!(point, label)
              exact!(point, %w[ancestors selector source_status subtree], label)
              string!(point["selector"], "#{label}.selector", 1_000)
              invalid!("#{label}.source_status is invalid") unless %w[available ambiguous external unavailable].include?(point["source_status"])
              ancestors = point["ancestors"]
              invalid!("#{label}.ancestors must contain at most 8 items") unless ancestors.is_a?(Array) && ancestors.length <= 8
              ancestors.each_with_index do |summary, nested|
                item = "#{label}.ancestors[#{nested}]"
                object!(summary, item)
                fields!(summary, %w[id name role tag], %w[tag], item)
                string!(summary["tag"], "#{item}.tag", 64)
                %w[id name role].each { |key| optional_string!(summary[key], "#{item}.#{key}", key == "name" ? 512 : 256) }
              end
              validate_node!(point["subtree"], "#{label}.subtree", 0)
            end
          end

          def validate_truncation!(entries)
            invalid!("truncation must be an array") unless entries.is_a?(Array)
            entries.each_with_index do |entry, index|
              label = "truncation[#{index}]"
              object!(entry, label)
              exact!(entry, %w[reasons section], label)
              string!(entry["section"], "#{label}.section", 16)
              invalid!("#{label}.section is invalid") unless entry["section"].match?(/\A(?:page|focus:[1-8])\z/)
              reasons = entry["reasons"]
              unless reasons.is_a?(Array) && !reasons.empty? && reasons.uniq == reasons && (reasons - %w[bytes nodes depth string]).empty?
                invalid!("#{label}.reasons is invalid")
              end
            end
          end

          def normalize_prompt(value)
            invalid!("prompt is required") unless value.is_a?(String)
            normalized = value.gsub("\r\n", "\n").gsub("\r", "\n").unicode_normalize(:nfc)
            normalized = normalized.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u202A-\u202E\u2066-\u2069]/, "").strip
            invalid!("prompt is required") if normalized.empty?
            invalid!("prompt must be at most 4000 bytes") if normalized.bytesize > 4_000
            normalized
          end

          def exact!(hash, allowed, label)
            fields!(hash, allowed, allowed, label)
          end

          def fields!(hash, allowed, required, label)
            unknown = hash.keys - allowed
            missing = required - hash.keys
            invalid!("#{label} has unknown field #{unknown.first.inspect}") unless unknown.empty?
            invalid!("#{label} is missing field #{missing.first.inspect}") unless missing.empty?
          end

          def object!(value, label)
            invalid!("#{label} must be an object") unless value.is_a?(Hash)
          end

          def string!(value, label, max)
            invalid!("#{label} is invalid") unless value.is_a?(String) && !value.empty? && value.bytesize <= max
          end

          def optional_string!(value, label, max)
            invalid!("#{label} is invalid") unless value.nil? || (value.is_a?(String) && value.bytesize <= max)
          end

          def strings!(values, label, max_items, max_bytes)
            valid = values.is_a?(Array) && values.length <= max_items && values.uniq == values &&
              values.all? { |value| value.is_a?(String) && !value.empty? && value.bytesize <= max_bytes }
            invalid!("#{label} is invalid") unless valid
          end

          def size!(value, max, message)
            invalid!(message) if JSON.generate(value).bytesize > max
          end

          def safe_json(value)
            canonical_json(value).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
          end

          def canonical_json(value)
            case value
            when Hash
              "{" + value.keys.sort.map { |key| "#{JSON.generate(key)}:#{canonical_json(value[key])}" }.join(",") + "}"
            when Array
              "[" + value.map { |item| canonical_json(item) }.join(",") + "]"
            else
              JSON.generate(value)
            end
          end

          def invalid!(message)
            raise Invalid, message
          end
        end
      end
    end
  end
end
