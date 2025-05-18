# frozen_string_literal: true

module MCPClient
  class ServerStdio
    # JSON-RPC request/notification plumbing for stdio transport
    module JsonRpcTransport
      # Ensure the server process is started and initialized (handshake)
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def ensure_initialized
        return if @initialized

        connect
        start_reader
        perform_initialize

        @initialized = true
      end

      # Handshake: send initialize request and initialized notification
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def perform_initialize
        # Initialize request
        init_id = next_id
        init_req = {
          'jsonrpc' => '2.0',
          'id' => init_id,
          'method' => 'initialize',
          'params' => {
            'protocolVersion' => MCPClient::PROTOCOL_VERSION,
            'capabilities' => {},
            'clientInfo' => { 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION }
          }
        }
        send_request(init_req)
        res = wait_response(init_id)
        if (err = res['error'])
          raise MCPClient::Errors::ConnectionError, "Initialize failed: #{err['message']}"
        end

        # Send initialized notification
        notif = { 'jsonrpc' => '2.0', 'method' => 'notifications/initialized', 'params' => {} }
        @stdin.puts(notif.to_json)
      end

      # Generate a new unique request ID
      # @return [Integer] a unique request ID
      def next_id
        @mutex.synchronize do
          id = @next_id
          @next_id += 1
          id
        end
      end

      # Send a JSON-RPC request and return nothing
      # @param req [Hash] the JSON-RPC request
      # @return [void]
      # @raise [MCPClient::Errors::TransportError] on write errors
      def send_request(req)
        @logger.debug("Sending JSONRPC request: #{req.to_json}")
        @stdin.puts(req.to_json)
      rescue StandardError => e
        raise MCPClient::Errors::TransportError, "Failed to send JSONRPC request: #{e.message}"
      end

      # Wait for a response with the given request ID
      # @param id [Integer] the request ID
      # @return [Hash] the JSON-RPC response message
      # @raise [MCPClient::Errors::TransportError] on timeout
      def wait_response(id)
        deadline = Time.now + @read_timeout
        @mutex.synchronize do
          until @pending.key?(id)
            remaining = deadline - Time.now
            break if remaining <= 0

            @cond.wait(@mutex, remaining)
          end
          msg = @pending[id]
          @pending[id] = nil
          raise MCPClient::Errors::TransportError, "Timeout waiting for JSONRPC response id=#{id}" unless msg

          msg
        end
      end

      # Stream tool call fallback for stdio transport (yields single result)
      # @param tool_name [String] the name of the tool to call
      # @param parameters [Hash] the parameters to pass to the tool
      # @return [Enumerator] a stream containing a single result
      def call_tool_streaming(tool_name, parameters)
        Enumerator.new do |yielder|
          yielder << call_tool(tool_name, parameters)
        end
      end

      # Generic JSON-RPC request: send method with params and wait for result
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the request
      # @return [Object] result from JSON-RPC response
      # @raise [MCPClient::Errors::ServerError] if server returns an error
      # @raise [MCPClient::Errors::TransportError] on transport errors
      # @raise [MCPClient::Errors::ToolCallError] on tool call errors
      def rpc_request(method, params = {})
        ensure_initialized
        attempts = 0
        begin
          req_id = next_id
          req = { 'jsonrpc' => '2.0', 'id' => req_id, 'method' => method, 'params' => params }
          send_request(req)
          res = wait_response(req_id)
          if (err = res['error'])
            raise MCPClient::Errors::ServerError, err['message']
          end

          res['result']
        rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError, IOError, Errno::ETIMEDOUT,
               Errno::ECONNRESET => e
          attempts += 1
          if attempts <= @max_retries
            delay = @retry_backoff * (2**(attempts - 1))
            @logger.debug("Retry attempt #{attempts} after error: #{e.message}, sleeping #{delay}s")
            sleep(delay)
            retry
          end
          raise
        end
      end

      # Send a JSON-RPC notification (no response expected)
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the notification
      # @return [void]
      def rpc_notify(method, params = {})
        ensure_initialized
        notif = { 'jsonrpc' => '2.0', 'method' => method, 'params' => params }
        @stdin.puts(notif.to_json)
      end
    end
  end
end
