# frozen_string_literal: true

require "json"

module AdapterSemantics
  VOLATILE_KEYS = %w[finished_at id started_at].freeze
  NORMALIZED_VALUE = "<adapter-specific>"

  module_function

  def normalize(value)
    case value
    when Hash
      value.to_h { |key, nested| [key, VOLATILE_KEYS.include?(key) ? NORMALIZED_VALUE : normalize(nested)] }
    when Array
      value.map { |nested| normalize(nested) }
    else
      value
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("../..", __dir__)
  rails = AdapterSemantics.normalize(JSON.parse(File.read(File.join(root, "build/conformance/rails.json"))))
  phoenix = AdapterSemantics.normalize(JSON.parse(File.read(File.join(root, "build/conformance/phoenix.json"))))

  unless rails == phoenix
    warn "Rails/Phoenix semantic drift detected"
    warn "Rails: #{JSON.pretty_generate(rails)}"
    warn "Phoenix: #{JSON.pretty_generate(phoenix)}"
    exit 1
  end

  puts "Rails/Phoenix semantics match after normalizing ID and timestamp values"
end
