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
          MAX_FOCUS_BYTES = 48 * 1024
          MAX_SNAPSHOT_NODES = 750
          FIELDS = %w[context prompt].freeze
          CONTEXT_FIELDS = %w[contract_version focus_points location route snapshot truncation].freeze
          NODE_FIELDS = %w[attributes children classes href id name role src state tag text].freeze
          ATTRIBUTE_FIELDS = %w[data-testid name placeholder type].freeze
          STATE_FIELDS = %w[checked disabled expanded invalid pressed required selected].freeze
          TRUNCATION_REASONS = %w[bytes nodes depth string].freeze

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
            @context = normalize_context(@value["context"])
            validate_context!
            self
          rescue EncodingError, JSON::GeneratorError
            invalid!("task contains invalid UTF-8")
          end

          def pi_prompt
            "#{prompt}\n\n--- BEGIN UNTRUSTED BROWSER CONTEXT ---\n#{safe_json(context)}\n--- END UNTRUSTED BROWSER CONTEXT ---"
          end

          private

          def normalize_context(value)
            object!(value, "context")
            normalized = normalize_value(value)
            normalize_location!(normalized["location"])
            normalize_route!(normalized["route"])
            normalize_node!(normalized["snapshot"])
            normalize_focus!(normalized["focus_points"])
            normalize_truncation!(normalized["truncation"])
            normalized
          end

          def normalize_value(value)
            case value
            when Hash then value.to_h { |key, nested| [key, normalize_value(nested)] }
            when Array then value.map { |nested| normalize_value(nested) }
            when String
              invalid!("task contains invalid UTF-8") unless value.valid_encoding?
              value.gsub("\r\n", "\n").gsub("\r", "\n").unicode_normalize(:nfc)
                .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]/, "")
            else value
            end
          end

          def structural(value)
            value.is_a?(String) ? value.gsub(/[[:space:]]+/, " ").strip : value
          end

          def normalize_location!(location)
            return unless location.is_a?(Hash)
            %w[origin path].each { |key| location[key] = structural(location[key]) }
            location["query_names"].map! { |name| structural(name) } if location["query_names"].is_a?(Array)
          end

          def normalize_route!(route)
            return unless route.is_a?(Hash)
            %w[pattern handler action].each { |key| route[key] = structural(route[key]) }
            route["method"] = normalize_case(route["method"], :upcase)
            route["action"] = nil if route["action"] == ""
          end

          def normalize_node!(node)
            return unless node.is_a?(Hash)
            node["tag"] = normalize_case(node["tag"], :downcase)
            %w[role name text id].each { |key| normalize_optional!(node, key) }
            node["classes"].map! { |value| structural(value) } if node["classes"].is_a?(Array)
            node.delete("classes") if node["classes"] == []
            if node["attributes"].is_a?(Hash)
              node["attributes"].keys.each { |key| normalize_optional!(node["attributes"], key) }
              node.delete("attributes") if node["attributes"].empty?
            end
            if node["state"].is_a?(Hash)
              node["state"].transform_values! { |value| value.is_a?(String) ? structural(value).downcase : value }
              node.delete("state") if node["state"].empty?
            end
            normalize_location!(node["href"])
            normalize_location!(node["src"])
            node["children"].each { |child| normalize_node!(child) } if node["children"].is_a?(Array)
          end

          def normalize_optional!(hash, key)
            return unless hash.key?(key)
            hash[key] = structural(hash[key])
            hash.delete(key) if hash[key] == ""
          end

          def normalize_focus!(points)
            return unless points.is_a?(Array)
            points.each do |point|
              next unless point.is_a?(Hash)
              point["selector"] = structural(point["selector"])
              point["source_status"] = normalize_case(point["source_status"], :downcase)
              next unless point["ancestors"].is_a?(Array)
              point["ancestors"].each do |summary|
                next unless summary.is_a?(Hash)
                summary["tag"] = normalize_case(summary["tag"], :downcase)
                %w[role name id].each { |key| normalize_optional!(summary, key) }
              end
              normalize_node!(point["subtree"])
            end
          end

          def normalize_truncation!(entries)
            return unless entries.is_a?(Array)
            entries.each do |entry|
              next unless entry.is_a?(Hash)
              entry["section"] = normalize_case(entry["section"], :downcase)
              if entry["reasons"].is_a?(Array)
                entry["reasons"].map! { |reason| normalize_case(reason, :downcase) }
                entry["reasons"].sort_by! { |reason| TRUNCATION_REASONS.index(reason) || TRUNCATION_REASONS.length }
              end
            end
            entries.sort_by! { |entry| entry.is_a?(Hash) ? truncation_order(entry["section"]) : 10 }
          end

          def truncation_order(section)
            section == "page" ? 0 : section.to_s.delete_prefix("focus:").to_i
          end

          def normalize_case(value, method)
            value.is_a?(String) ? structural(value).public_send(method) : value
          end

          def validate_context!
            exact!(context, CONTEXT_FIELDS, "context")
            invalid!("contract_version must be 1") unless context["contract_version"] == 1
            validate_location!(context["location"], "location")
            validate_route!(context["route"])
            count = validate_node!(context["snapshot"], "snapshot", 0, 12)
            invalid!("snapshot must contain at most 750 nodes") if count > MAX_SNAPSHOT_NODES
            size!(context["snapshot"], MAX_SNAPSHOT_BYTES, "snapshot is too large")
            validate_focus!(context["focus_points"])
            validate_truncation!(context["truncation"])
            size!(context, MAX_CONTEXT_BYTES, "context is too large")
          end

          def validate_location!(location, label)
            object!(location, label)
            exact!(location, %w[origin path query_names], label)
            string!(location["origin"], "#{label}.origin", 512)
            uri = URI.parse(location["origin"])
            unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query &&
                   !uri.fragment && [nil, ""].include?(uri.path)
              invalid!("#{label}.origin must be an HTTP(S) origin without credentials or path")
            end
            string!(location["path"], "#{label}.path", 2_048)
            unless location["path"].start_with?("/") && !location["path"].match?(/[?#]/)
              invalid!("#{label}.path is invalid")
            end
            strings!(location["query_names"], "#{label}.query_names", 32, 128)
          rescue URI::InvalidURIError
            invalid!("#{label}.origin must be an HTTP(S) origin without credentials or path")
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

          def validate_node!(node, label, depth, maximum_depth)
            object!(node, label)
            invalid!("#{label} exceeds maximum depth") if depth > maximum_depth
            fields!(node, NODE_FIELDS, %w[children tag], label)
            string!(node["tag"], "#{label}.tag", 64)
            invalid!("#{label}.tag is invalid") unless node["tag"].match?(/\A[a-z][a-z0-9-]*\z/)
            optional_string!(node["role"], "#{label}.role", 64)
            optional_string!(node["name"], "#{label}.name", 512)
            optional_string!(node["text"], "#{label}.text", 1_000)
            optional_string!(node["id"], "#{label}.id", 256)
            strings!(node["classes"], "#{label}.classes", 32, 128) unless node["classes"].nil?
            validate_attributes!(node["attributes"], "#{label}.attributes") unless node["attributes"].nil?
            validate_state!(node["state"], "#{label}.state") unless node["state"].nil?
            validate_location!(node["href"], "#{label}.href") unless node["href"].nil?
            validate_location!(node["src"], "#{label}.src") unless node["src"].nil?
            invalid!("#{label}.children must be an array") unless node["children"].is_a?(Array)
            1 + node["children"].each_with_index.sum do |child, index|
              validate_node!(child, "#{label}.children[#{index}]", depth + 1, maximum_depth)
            end
          end

          def validate_attributes!(attributes, label)
            object!(attributes, label)
            fields!(attributes, ATTRIBUTE_FIELDS, [], label)
            attributes.each { |key, value| string!(value, "#{label}.#{key}", 256) }
          end

          def validate_state!(state, label)
            object!(state, label)
            fields!(state, STATE_FIELDS, [], label)
            %w[disabled expanded required selected].each do |key|
              invalid!("#{label}.#{key} is invalid") if state.key?(key) && !boolean?(state[key])
            end
            %w[checked pressed].each do |key|
              invalid!("#{label}.#{key} is invalid") if state.key?(key) && ![true, false, "mixed"].include?(state[key])
            end
            if state.key?("invalid") && ![true, false, "grammar", "spelling"].include?(state["invalid"])
              invalid!("#{label}.invalid is invalid")
            end
          end

          def validate_focus!(points)
            invalid!("focus_points must contain at most 8 items") unless points.is_a?(Array) && points.length <= 8
            selectors = []
            points.each_with_index do |point, index|
              label = "focus_points[#{index}]"
              object!(point, label)
              exact!(point, %w[ancestors selector source_status subtree], label)
              string!(point["selector"], "#{label}.selector", 1_000)
              selectors << point["selector"]
              invalid!("#{label}.source_status is invalid") unless %w[available ambiguous external unavailable].include?(point["source_status"])
              ancestors = point["ancestors"]
              invalid!("#{label}.ancestors must contain at most 8 items") unless ancestors.is_a?(Array) && ancestors.length <= 8
              ancestors.each_with_index { |summary, nested| validate_summary!(summary, "#{label}.ancestors[#{nested}]") }
              count = validate_node!(point["subtree"], "#{label}.subtree", 0, 6)
              invalid!("#{label}.subtree must contain at most 100 nodes") if count > 100
            end
            invalid!("focus_points selectors must be unique") unless selectors.uniq == selectors
            size!(points, MAX_FOCUS_BYTES, "focus_points are too large")
          end

          def validate_summary!(summary, label)
            object!(summary, label)
            fields!(summary, %w[id name role tag], %w[tag], label)
            string!(summary["tag"], "#{label}.tag", 64)
            invalid!("#{label}.tag is invalid") unless summary["tag"].match?(/\A[a-z][a-z0-9-]*\z/)
            optional_string!(summary["role"], "#{label}.role", 64)
            optional_string!(summary["name"], "#{label}.name", 512)
            optional_string!(summary["id"], "#{label}.id", 256)
          end

          def validate_truncation!(entries)
            invalid!("truncation must be an array") unless entries.is_a?(Array)
            sections = []
            entries.each_with_index do |entry, index|
              label = "truncation[#{index}]"
              object!(entry, label)
              exact!(entry, %w[reasons section], label)
              string!(entry["section"], "#{label}.section", 16)
              invalid!("#{label}.section is invalid") unless entry["section"].match?(/\A(?:page|focus:[1-8])\z/)
              sections << entry["section"]
              reasons = entry["reasons"]
              unless reasons.is_a?(Array) && !reasons.empty? && reasons.uniq == reasons &&
                     (reasons - TRUNCATION_REASONS).empty?
                invalid!("#{label}.reasons is invalid")
              end
            end
            invalid!("truncation sections must be unique") unless sections.uniq == sections
          end

          def normalize_prompt(value)
            invalid!("prompt is required") unless value.is_a?(String) && value.valid_encoding?
            normalized = normalize_value(value).strip
            invalid!("prompt is required") if normalized.empty?
            invalid!("prompt must be at most 4000 bytes") if normalized.bytesize > 4_000
            normalized
          end

          def exact!(hash, allowed, label)
            fields!(hash, allowed, allowed, label)
          end

          def fields!(hash, allowed, required, label)
            unknown = (hash.keys - allowed).sort
            missing = (required - hash.keys).sort
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

          def boolean?(value)
            value == true || value == false
          end

          def invalid!(message)
            raise Invalid, message
          end
        end
      end
    end
  end
end
