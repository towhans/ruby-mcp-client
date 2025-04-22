# frozen_string_literal: true

# Load all MCP components
require_relative "mcp/errors"
require_relative "mcp/tool"
require_relative "mcp/server_base"
require_relative "mcp/server_stdio"
require_relative "mcp/server_sse"
require_relative "mcp/server_factory"
require_relative "mcp/client"

# Model Context Protocol (MCP) module
# Provides a standardized way for agents to communicate with external tools and services
# through a protocol-based approach
module MCP
  # Create a new MCP client
  # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
  # @return [MCP::Client] new client instance
  def self.create_client(mcp_server_configs: [])
    MCP::Client.new(mcp_server_configs: mcp_server_configs)
  end

  # Create a standard server configuration for stdio
  # @param command [String, Array<String>] command to execute
  # @return [Hash] server configuration
  def self.stdio_config(command:)
    {
      type: "stdio",
      command: command
    }
  end

  # Create a standard server configuration for SSE
  # @param base_url [String] base URL for the server
  # @param headers [Hash] HTTP headers to include in requests
  # @return [Hash] server configuration
  def self.sse_config(base_url:, headers: {})
    {
      type: "sse",
      base_url: base_url,
      headers: headers
    }
  end
end

## Note: example integrations have been moved to the 'examples/' directory and are not auto-required
