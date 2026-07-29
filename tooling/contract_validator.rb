# frozen_string_literal: true

require "json"
require "pathname"

module ContractValidation
  class SchemaValidator
    JSON_TYPES = {
      "array" => Array,
      "boolean" => [TrueClass, FalseClass],
      "integer" => Integer,
      "null" => NilClass,
      "number" => Numeric,
      "object" => Hash,
      "string" => String
    }.freeze

    def initialize(registry)
      @registry = registry
    end

    def validate(value, schema, path: "$", root_schema: schema)
      errors = []

      if schema.key?("$ref")
        referenced, referenced_root = resolve(schema.fetch("$ref"), root_schema)
        errors.concat(validate(value, referenced, path: path, root_schema: referenced_root))
      end

      errors << "#{path}: expected #{schema.fetch("const").inspect}" if schema.key?("const") && value != schema["const"]

      if schema.key?("enum") && !schema.fetch("enum").include?(value)
        errors << "#{path}: expected one of #{schema.fetch("enum").inspect}"
      end

      expected_types = Array(schema["type"])
      unless expected_types.empty? || expected_types.any? { |type| type_match?(value, type) }
        errors << "#{path}: expected type #{expected_types.join(" or ")}"
        return errors
      end

      errors.concat(validate_object(value, schema, path, root_schema)) if value.is_a?(Hash)
      errors.concat(validate_array(value, schema, path, root_schema)) if value.is_a?(Array)
      errors.concat(validate_string(value, schema, path)) if value.is_a?(String)
      errors.concat(validate_number(value, schema, path)) if value.is_a?(Numeric)
      errors
    end

    private

    def resolve(reference, current_root)
      document, fragment = reference.split("#", 2)
      root = document.nil? || document.empty? ? current_root : @registry.fetch(document)
      target = fragment.nil? || fragment.empty? ? root : resolve_pointer(root, fragment)
      [target, root]
    rescue KeyError
      raise ArgumentError, "unresolved schema reference #{reference}"
    end

    def resolve_pointer(root, fragment)
      fragment.sub(%r{^/}, "").split("/").reduce(root) do |value, token|
        value.fetch(token.gsub("~1", "/").gsub("~0", "~"))
      end
    end

    def type_match?(value, type)
      klass = JSON_TYPES.fetch(type) { raise ArgumentError, "unsupported schema type #{type}" }
      return false if type == "integer" && (value.is_a?(TrueClass) || value.is_a?(FalseClass))
      return false if type == "number" && (value.is_a?(TrueClass) || value.is_a?(FalseClass))

      Array(klass).any? { |candidate| value.is_a?(candidate) }
    end

    def validate_object(value, schema, path, root_schema)
      errors = []
      required = schema.fetch("required", [])
      required.each do |key|
        errors << "#{path}: missing required property #{key}" unless value.key?(key)
      end

      properties = schema.fetch("properties", {})
      value.each do |key, child|
        if properties.key?(key)
          errors.concat(validate(child, properties.fetch(key), path: "#{path}.#{key}", root_schema: root_schema))
        elsif schema["additionalProperties"] == false
          errors << "#{path}: unknown property #{key}"
        end
      end
      errors
    end

    def validate_array(value, schema, path, root_schema)
      errors = []
      errors << "#{path}: expected at least #{schema["minItems"]} items" if schema["minItems"] && value.length < schema["minItems"]
      errors << "#{path}: expected at most #{schema["maxItems"]} items" if schema["maxItems"] && value.length > schema["maxItems"]
      if schema["uniqueItems"] && value.map { |item| JSON.generate(item) }.uniq.length != value.length
        errors << "#{path}: expected unique items"
      end
      if schema["items"]
        value.each_with_index do |child, index|
          errors.concat(validate(child, schema.fetch("items"), path: "#{path}[#{index}]", root_schema: root_schema))
        end
      end
      errors
    end

    def validate_string(value, schema, path)
      errors = []
      errors << "#{path}: string is shorter than #{schema["minLength"]}" if schema["minLength"] && value.length < schema["minLength"]
      errors << "#{path}: string is longer than #{schema["maxLength"]}" if schema["maxLength"] && value.length > schema["maxLength"]
      if schema["pattern"] && !Regexp.new(schema.fetch("pattern")).match?(value)
        errors << "#{path}: does not match #{schema.fetch("pattern")}"
      end
      errors
    end

    def validate_number(value, schema, path)
      errors = []
      errors << "#{path}: must be at least #{schema["minimum"]}" if schema["minimum"] && value < schema["minimum"]
      errors << "#{path}: must be at most #{schema["maximum"]}" if schema["maximum"] && value > schema["maximum"]
      errors
    end
  end

  class Runner
    META_SCHEMA = "https://json-schema.org/draft/2020-12/schema"
    ALLOWED_TYPES = SchemaValidator::JSON_TYPES.keys.freeze

    def initialize(root)
      @root = Pathname(root)
      @contract = @root.join("contract")
      @schemas = load_schemas
      @validator = SchemaValidator.new(@schemas)
    end

    def run
      validate_schema_definitions
      validate_manifest_and_fixtures
      puts "contract schemas and fixtures are valid"
    end

    private

    def load_schemas
      @contract.join("schemas").glob("*.schema.json").each_with_object({}) do |path, schemas|
        schema = JSON.parse(path.read)
        id = schema.fetch("$id")
        raise "duplicate schema id #{id}" if schemas.key?(id)

        schemas[id] = schema
      rescue JSON::ParserError => error
        raise "#{path.relative_path_from(@root)}: invalid JSON: #{error.message}"
      end
    end

    def validate_schema_definitions
      @schemas.each_value do |schema|
        raise "#{schema["$id"]}: unsupported meta-schema" unless schema["$schema"] == META_SCHEMA
        validate_schema_node(schema, schema.fetch("$id"), schema)
      end
    end

    def validate_schema_node(node, location, root_schema)
      types = Array(node["type"])
      unknown_types = types - ALLOWED_TYPES
      raise "#{location}: unsupported types #{unknown_types.join(", ")}" unless unknown_types.empty?
      raise "#{location}: properties must be an object" if node.key?("properties") && !node["properties"].is_a?(Hash)
      raise "#{location}: required must be unique" if node["required"]&.then { |keys| keys.uniq.length != keys.length }

      @validator.send(:resolve, node.fetch("$ref"), root_schema) if node.key?("$ref")
      node.fetch("properties", {}).each do |key, child|
        validate_schema_node(child, "#{location}.properties.#{key}", root_schema)
      end
      node.fetch("$defs", {}).each do |key, child|
        validate_schema_node(child, "#{location}.$defs.#{key}", root_schema)
      end
      if node["items"].is_a?(Hash)
        validate_schema_node(node.fetch("items"), "#{location}.items", root_schema)
      end
    end

    def validate_manifest_and_fixtures
      manifest_path = @contract.join("fixtures/manifest.json")
      manifest = JSON.parse(manifest_path.read)
      manifest_schema = @schemas.fetch(
        "https://pi-browser-taskbar.dev/contract/schemas/fixture-manifest.v1.schema.json"
      )
      manifest_errors = @validator.validate(manifest, manifest_schema)
      raise "fixture manifest invalid:\n#{manifest_errors.join("\n")}" unless manifest_errors.empty?

      ids = manifest.fetch("fixtures").map { |entry| entry.fetch("id") }
      raise "fixture ids must be unique" unless ids.uniq.length == ids.length
      raise "manifest must include a rejecting fixture" unless manifest.fetch("fixtures").any? { |entry| !entry.fetch("expected_valid") }

      manifest.fetch("fixtures").each { |entry| validate_fixture(entry) }
      validate_prompt_goldens(manifest)
    end

    def validate_prompt_goldens(manifest)
      prompt_schema = "https://pi-browser-taskbar.dev/contract/schemas/prompt-golden.v1.schema.json"
      manifest.fetch("fixtures").select { |entry| entry.fetch("schema") == prompt_schema }.each do |entry|
        golden = JSON.parse(@contract.join(entry.fetch("path")).read)
        context_path = Pathname(golden.fetch("context_fixture"))
        if context_path.absolute? || context_path.each_filename.include?("..")
          raise "#{entry["id"]}: context fixture path may not traverse"
        end

        context = JSON.parse(@contract.join(context_path).read)
        canonical_context = JSON.generate(canonicalize(context))
        expected = [
          golden.fetch("instruction"),
          "",
          "--- BEGIN UNTRUSTED BROWSER CONTEXT ---",
          canonical_context,
          "--- END UNTRUSTED BROWSER CONTEXT ---"
        ].join("\n")
        raise "#{entry["id"]}: prompt golden is stale" unless golden.fetch("expected") == expected
      end
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end

    def validate_fixture(entry)
      relative = Pathname(entry.fetch("path"))
      raise "#{entry["id"]}: fixture path may not traverse" if relative.absolute? || relative.each_filename.include?("..")

      path = @contract.join(relative)
      raise "#{entry["id"]}: missing fixture #{relative}" unless path.file?

      value = JSON.parse(path.read)
      schema = @schemas.fetch(entry.fetch("schema"))
      errors = @validator.validate(value, schema)

      if entry.fetch("expected_valid")
        raise "#{entry["id"]}: expected valid fixture:\n#{errors.join("\n")}" unless errors.empty?
      else
        raise "#{entry["id"]}: invalid fixture was accepted" if errors.empty?
        fragment = entry.fetch("error_contains")
        raise "#{entry["id"]}: rejection did not include #{fragment.inspect}: #{errors.inspect}" unless errors.any? { |error| error.include?(fragment) }
      end
    rescue JSON::ParserError => error
      raise "#{entry["id"]}: malformed fixture JSON: #{error.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  ContractValidation::Runner.new(root).run
end
