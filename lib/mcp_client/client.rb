# frozen_string_literal: true

module MCPClient
  # MCP Client for integrating with the Model Context Protocol
  # This is the main entry point for using MCP tools
  class Client
    attr_reader :servers, :tool_cache

    def initialize(mcp_server_configs: [])
      @servers = mcp_server_configs.map { |config| MCPClient::ServerFactory.create(config) }
      @tool_cache = {}
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

      # Find the server that owns this tool
      server = find_server_for_tool(tool)
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      server.call_tool(tool_name, parameters)
    end

    # Convert MCP tools to OpenAI function specifications
    # @return [Array<Hash>] OpenAI function specifications
    def to_openai_tools
      list_tools.map(&:to_openai_tool)
    end

    # Convert MCP tools to Anthropic Claude tool specifications
    # @return [Array<Hash>] Anthropic Claude tool specifications
    def to_anthropic_tools
      list_tools.map(&:to_anthropic_tool)
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

    private

    def find_server_for_tool(tool)
      servers.find do |server|
        server.list_tools.any? { |t| t.name == tool.name }
      end
    end
  end
end
