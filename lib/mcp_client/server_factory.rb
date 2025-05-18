# frozen_string_literal: true

module MCPClient
  # Factory for creating MCP server instances based on configuration
  class ServerFactory
    # Create a server instance based on configuration
    # @param config [Hash] server configuration
    # @param logger [Logger, nil] optional logger to use for the server
    # @return [MCPClient::ServerBase] server instance
    def self.create(config, logger: nil)
      case config[:type]
      when 'stdio'
        MCPClient::ServerStdio.new(
          command: config[:command],
          retries: config[:retries] || 0,
          retry_backoff: config[:retry_backoff] || 1,
          read_timeout: config[:read_timeout] || MCPClient::ServerStdio::READ_TIMEOUT,
          name: config[:name],
          logger: config[:logger] || logger,
          env: config[:env] || {}
        )
      when 'sse'
        MCPClient::ServerSSE.new(
          base_url: config[:base_url],
          headers: config[:headers] || {},
          read_timeout: config[:read_timeout] || 30,
          ping: config[:ping] || 10,
          retries: config[:retries] || 0,
          retry_backoff: config[:retry_backoff] || 1,
          name: config[:name],
          logger: config[:logger] || logger
        )
      else
        raise ArgumentError, "Unknown server type: #{config[:type]}"
      end
    end
  end
end
