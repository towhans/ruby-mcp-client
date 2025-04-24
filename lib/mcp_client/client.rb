# frozen_string_literal: true

require 'logger'

module MCPClient
  # MCP Client for integrating with the Model Context Protocol
  # This is the main entry point for using MCP tools
  class Client
    # @!attribute [r] servers
    #   @return [Array<MCPClient::ServerBase>] list of servers
    # @!attribute [r] tool_cache
    #   @return [Hash<String, MCPClient::Tool>] cache of tools by name
    # @!attribute [r] logger
    #   @return [Logger] logger for client operations
    attr_reader :servers, :tool_cache, :logger

    # Initialize a new MCPClient::Client
    # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
    # @param logger [Logger, nil] optional logger, defaults to STDOUT
    def initialize(mcp_server_configs: [], logger: nil)
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @servers = mcp_server_configs.map do |config|
        @logger.debug("Creating server with config: #{config.inspect}")
        MCPClient::ServerFactory.create(config)
      end
      @tool_cache = {}
      # JSON-RPC notification listeners
      @notification_listeners = []
      # Register default and user-defined notification handlers on each server
      @servers.each do |server|
        server.on_notification do |method, params|
          # Default handling: clear tool cache on tools list change
          clear_cache if method == 'notifications/tools/list_changed'
          # Invoke user listeners
          @notification_listeners.each { |cb| cb.call(server, method, params) }
        end
      end
    end

    # Lists all available tools from all connected MCP servers
    # @param cache [Boolean] whether to use cached tools or fetch fresh
    # @return [Array<MCPClient::Tool>] list of available tools
    def list_tools(cache: true)
      return @tool_cache.values if cache && !@tool_cache.empty?

      tools = []
      servers.each do |server|
        server.list_tools.each do |tool|
          @tool_cache[tool.name] = tool
          tools << tool
        end
      end

      tools
    end

    # Calls a specific tool by name with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    def call_tool(tool_name, parameters)
      tools = list_tools
      tool = tools.find { |t| t.name == tool_name }

      raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found" unless tool

      # Validate parameters against tool schema
      validate_params!(tool, parameters)

      # Find the server that owns this tool
      server = find_server_for_tool(tool)
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      server.call_tool(tool_name, parameters)
    end

    # Convert MCP tools to OpenAI function specifications
    # @param tool_names [Array<String>, nil] optional list of tool names to include, nil means all tools
    # @return [Array<Hash>] OpenAI function specifications
    def to_openai_tools(tool_names: nil)
      tools = list_tools
      tools = tools.select { |t| tool_names.include?(t.name) } if tool_names
      tools.map(&:to_openai_tool)
    end

    # Convert MCP tools to Anthropic Claude tool specifications
    # @param tool_names [Array<String>, nil] optional list of tool names to include, nil means all tools
    # @return [Array<Hash>] Anthropic Claude tool specifications
    def to_anthropic_tools(tool_names: nil)
      tools = list_tools
      tools = tools.select { |t| tool_names.include?(t.name) } if tool_names
      tools.map(&:to_anthropic_tool)
    end

    # Clean up all server connections
    def cleanup
      servers.each(&:cleanup)
    end

    # Clear the cached tools so that next list_tools will fetch fresh data
    # @return [void]
    def clear_cache
      @tool_cache.clear
    end

    # Register a callback for JSON-RPC notifications from servers
    # @yield [server, method, params]
    # @return [void]
    def on_notification(&block)
      @notification_listeners << block
    end

    # Find all tools whose name matches the given pattern (String or Regexp)
    # @param pattern [String, Regexp] pattern to match tool names
    # @return [Array<MCPClient::Tool>] matching tools
    def find_tools(pattern)
      rx = pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern)}/
      list_tools.select { |t| t.name.match(rx) }
    end

    # Find the first tool whose name matches the given pattern
    # @param pattern [String, Regexp] pattern to match tool names
    # @return [MCPClient::Tool, nil]
    def find_tool(pattern)
      find_tools(pattern).first
    end

    # Call multiple tools in batch
    # @param calls [Array<Hash>] array of calls in the form { name: tool_name, parameters: {...} }
    # @return [Array<Object>] array of results for each tool invocation
    def call_tools(calls)
      calls.map do |call|
        name = call[:name] || call['name']
        params = call[:parameters] || call['parameters'] || {}
        call_tool(name, params)
      end
    end

    # Stream call of a specific tool by name with the given parameters.
    # Returns an Enumerator yielding streaming updates if supported.
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Enumerator] streaming enumerator or single-value enumerator
    def call_tool_streaming(tool_name, parameters)
      tools = list_tools
      tool = tools.find { |t| t.name == tool_name }
      raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found" unless tool

      # Validate parameters against tool schema
      validate_params!(tool, parameters)
      # Find the server that owns this tool
      server = find_server_for_tool(tool)
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      if server.respond_to?(:call_tool_streaming)
        server.call_tool_streaming(tool_name, parameters)
      else
        Enumerator.new do |yielder|
          yielder << server.call_tool(tool_name, parameters)
        end
      end
    end

    private

    # Validate parameters against tool JSON schema (checks required properties)
    # @param tool [MCPClient::Tool] tool definition with schema
    # @param parameters [Hash] parameters to validate
    # @raise [MCPClient::Errors::ValidationError] when required params are missing
    def validate_params!(tool, parameters)
      schema = tool.schema
      return unless schema.is_a?(Hash)

      required = schema['required'] || schema[:required]
      return unless required.is_a?(Array)

      missing = required.map(&:to_s) - parameters.keys.map(&:to_s)
      return unless missing.any?

      raise MCPClient::Errors::ValidationError, "Missing required parameters: #{missing.join(', ')}"
    end

    def find_server_for_tool(tool)
      servers.find do |server|
        server.list_tools.any? { |t| t.name == tool.name }
      end
    end
  end
end
