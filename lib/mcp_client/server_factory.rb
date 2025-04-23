# frozen_string_literal: true

module MCPClient
  # Factory for creating MCP server instances based on configuration
  class ServerFactory
    # Create a server instance based on configuration
    # @param config [Hash] server configuration
    # @return [MCPClient::ServerBase] server instance
    def self.create(config)
      case config[:type]
      when 'stdio'
        MCPClient::ServerStdio.new(command: config[:command])
      when 'sse'
        MCPClient::ServerSSE.new(
          base_url: config[:base_url],
          headers: config[:headers] || {},
          read_timeout: config[:read_timeout] || 30
        )
      else
        raise ArgumentError, "Unknown server type: #{config[:type]}"
      end
    end
  end
end
