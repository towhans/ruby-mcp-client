# frozen_string_literal: true

module MCP
  # Factory for creating MCP server instances based on configuration
  class ServerFactory
    # Create a server instance based on configuration
    # @param config [Hash] server configuration
    # @return [MCP::ServerBase] server instance
    def self.create(config)
      case config[:type]
      when "stdio"
        MCP::ServerStdio.new(command: config[:command])
      when "sse"
        MCP::ServerSSE.new(
          base_url: config[:base_url],
          headers: config[:headers] || {}
        )
      else
        raise ArgumentError, "Unknown server type: #{config[:type]}"
      end
    end
  end
end
