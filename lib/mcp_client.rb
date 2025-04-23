# frozen_string_literal: true

# Load all MCPClient components
require_relative 'mcp_client/errors'
require_relative 'mcp_client/tool'
require_relative 'mcp_client/server_base'
require_relative 'mcp_client/server_stdio'
require_relative 'mcp_client/server_sse'
require_relative 'mcp_client/server_factory'
require_relative 'mcp_client/client'
require_relative 'mcp_client/version'

# Model Context Protocol (MCP) Client module
# Provides a standardized way for agents to communicate with external tools and services
# through a protocol-based approach
module MCPClient
  # Create a new MCPClient client
  # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
  # @return [MCPClient::Client] new client instance
  def self.create_client(mcp_server_configs: [])
    MCPClient::Client.new(mcp_server_configs: mcp_server_configs)
  end

  # Create a standard server configuration for stdio
  # @param command [String, Array<String>] command to execute
  # @return [Hash] server configuration
  def self.stdio_config(command:)
    {
      type: 'stdio',
      command: command
    }
  end

  # Create a standard server configuration for SSE
  # @param base_url [String] base URL for the server
  # @param headers [Hash] HTTP headers to include in requests
  # @param read_timeout [Integer] read timeout in seconds (default: 30)
  # @return [Hash] server configuration
  def self.sse_config(base_url:, headers: {}, read_timeout: 30)
    {
      type: 'sse',
      base_url: base_url,
      headers: headers,
      read_timeout: read_timeout
    }
  end
end
