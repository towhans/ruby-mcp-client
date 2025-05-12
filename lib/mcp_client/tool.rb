# frozen_string_literal: true

module MCPClient
  # Representation of an MCP tool
  class Tool
    attr_reader :name, :description, :schema

    def initialize(name:, description:, schema:)
      @name = name
      @description = description
      @schema = schema
    end

    # Create a Tool instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @return [MCPClient::Tool] tool instance
    def self.from_json(data)
      # Some servers (Playwright MCP CLI) use 'inputSchema' instead of 'schema'
      schema = data['inputSchema'] || data['schema']
      new(
        name: data['name'],
        description: data['description'],
        schema: schema
      )
    end

    # Convert tool to OpenAI function specification format
    # @return [Hash] OpenAI function specification
    def to_openai_tool
      {
        type: 'function',
        function: {
          name: @name,
          description: @description,
          parameters: @schema
        }
      }
    end

    # Convert tool to Anthropic Claude tool specification format
    # @return [Hash] Anthropic Claude tool specification
    def to_anthropic_tool
      {
        name: @name,
        description: @description,
        input_schema: @schema
      }
    end

    def to_google_tool
      {
        name: @name,
        description: @description,
        parameters: cleaned_schema(@schema)
      }
    end

    private

    # Recursively remove "$schema" keys that are not accepted by Vertex AI
    # @param obj [Object] schema element (Hash/Array/other)
    # @return [Object] cleaned schema without "$schema" keys
    def cleaned_schema(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          next if k == '$schema'

          h[k] = cleaned_schema(v)
        end
      when Array
        obj.map { |v| cleaned_schema(v) }
      else
        obj
      end
    end
  end
end
