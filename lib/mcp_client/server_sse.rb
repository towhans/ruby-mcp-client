# frozen_string_literal: true

require 'uri'
require 'json'
require 'monitor'
require 'logger'
require 'faraday'
require 'faraday/retry'

module MCPClient
  # Implementation of MCP server that communicates via Server-Sent Events (SSE)
  # Useful for communicating with remote MCP servers over HTTP
  class ServerSSE < ServerBase
    attr_reader :base_url, :tools, :server_info, :capabilities

    # @param base_url [String] The base URL of the MCP server
    # @param headers [Hash] Additional headers to include in requests
    # @param read_timeout [Integer] Read timeout in seconds (default: 30)
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param logger [Logger, nil] optional logger
    def initialize(base_url:, headers: {}, read_timeout: 30, retries: 0, retry_backoff: 1, logger: nil)
      super()
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @logger.progname = self.class.name
      @logger.formatter = proc { |severity, _datetime, progname, msg| "#{severity} [#{progname}] #{msg}\n" }
      @max_retries = retries
      @retry_backoff = retry_backoff
      # Normalize base_url: strip any trailing slash, use exactly as provided
      @base_url = base_url.chomp('/')
      @headers = headers.merge({
                                 'Accept' => 'text/event-stream',
                                 'Cache-Control' => 'no-cache',
                                 'Connection' => 'keep-alive'
                               })
      # HTTP client is managed via Faraday
      @tools = nil
      @read_timeout = read_timeout

      # SSE-provided JSON-RPC endpoint path for POST requests
      @rpc_endpoint = nil
      @tools_data = nil
      @request_id = 0
      @sse_results = {}
      @mutex = Monitor.new
      @buffer = ''
      @sse_connected = false
      @connection_established = false
      @connection_cv = @mutex.new_cond
      @initialized = false
      # Whether to use SSE transport; may disable if handshake fails
      @use_sse = true
    end

    # Stream tool call fallback for SSE transport (yields single result)
    # @param tool_name [String]
    # @param parameters [Hash]
    # @return [Enumerator]
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      @mutex.synchronize do
        return @tools if @tools
      end

      ensure_initialized

      begin
        tools_data = request_tools_list
        @mutex.synchronize do
          @tools = tools_data.map do |tool_data|
            MCPClient::Tool.from_json(tool_data)
          end
        end

        @mutex.synchronize { @tools }
      rescue MCPClient::Errors::TransportError
        # Re-raise TransportError directly
        raise
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      rescue StandardError => e
        raise MCPClient::Errors::ToolCallError, "Error listing tools: #{e.message}"
      end
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool execution
    def call_tool(tool_name, parameters)
      ensure_initialized

      begin
        request_id = @mutex.synchronize { @request_id += 1 }

        json_rpc_request = {
          jsonrpc: '2.0',
          id: request_id,
          method: 'tools/call',
          params: {
            name: tool_name,
            arguments: parameters
          }
        }

        send_jsonrpc_request(json_rpc_request)
      rescue MCPClient::Errors::TransportError
        # Re-raise TransportError directly
        raise
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      rescue StandardError => e
        raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
      end
    end

    # Connect to the MCP server over HTTP/HTTPS with SSE
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      @mutex.synchronize do
        return true if @connection_established

        # Start SSE listener using Faraday HTTP client
        start_sse_thread

        timeout = 10
        success = @connection_cv.wait(timeout) { @connection_established }

        unless success
          cleanup
          raise MCPClient::Errors::ConnectionError, 'Timed out waiting for SSE connection to be established'
        end

        @connection_established
      end
    rescue StandardError => e
      cleanup
      raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached tools
    def cleanup
      @mutex.synchronize do
        begin
          @sse_thread&.kill
        rescue StandardError
          nil
        end
        @sse_thread = nil

        if @http_client
          @http_client.finish if @http_client.started?
          @http_client = nil
        end

        @tools = nil
        @connection_established = false
        @sse_connected = false
      end
    end

    # Generic JSON-RPC request: send method with params and return result
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @return [Object] result from JSON-RPC response
    def rpc_request(method, params = {})
      ensure_initialized
      with_retry do
        request_id = @mutex.synchronize { @request_id += 1 }
        request = { jsonrpc: '2.0', id: request_id, method: method, params: params }
        send_jsonrpc_request(request)
      end
    end

    # Send a JSON-RPC notification (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @return [void]
    def rpc_notify(method, params = {})
      ensure_initialized
      uri = URI.parse(@base_url)
      base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      rpc_ep = @mutex.synchronize { @rpc_endpoint }
      @rpc_conn ||= Faraday.new(url: base) do |f|
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.options.open_timeout = @read_timeout
        f.options.timeout = @read_timeout
        f.adapter Faraday.default_adapter
      end
      response = @rpc_conn.post(rpc_ep) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Accept'] = 'application/json'
        (@headers.dup.tap do |h|
          h.delete('Accept')
          h.delete('Cache-Control')
        end).each do |k, v|
          req.headers[k] = v
        end
        req.body = { jsonrpc: '2.0', method: method, params: params }.to_json
      end
      unless response.success?
        raise MCPClient::Errors::ServerError, "Notification failed: #{response.status} #{response.reason_phrase}"
      end
    rescue StandardError => e
      raise MCPClient::Errors::TransportError, "Failed to send notification: #{e.message}"
    end

    private

    # Ensure SSE initialization handshake has been performed
    def ensure_initialized
      return if @initialized

      connect
      perform_initialize

      @initialized = true
    end

    # Perform JSON-RPC initialize handshake with the MCP server
    def perform_initialize
      request_id = @mutex.synchronize { @request_id += 1 }
      json_rpc_request = {
        jsonrpc: '2.0',
        id: request_id,
        method: 'initialize',
        params: {
          'protocolVersion' => MCPClient::VERSION,
          'capabilities' => {},
          'clientInfo' => { 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION }
        }
      }
      @logger.debug("Performing initialize RPC: #{json_rpc_request}")
      result = send_jsonrpc_request(json_rpc_request)
      return unless result.is_a?(Hash)

      @server_info = result['serverInfo'] if result.key?('serverInfo')
      @capabilities = result['capabilities'] if result.key?('capabilities')
    end

    # Start the SSE thread to listen for events
    def start_sse_thread
      return if @sse_thread&.alive?

      @sse_thread = Thread.new do
        uri = URI.parse(@base_url)
        sse_base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        sse_path = uri.request_uri

        @sse_conn ||= Faraday.new(url: sse_base) do |f|
          f.options.open_timeout = 10
          f.options.timeout = nil
          f.adapter Faraday.default_adapter
        end

        @sse_conn.get(sse_path) do |req|
          @headers.each { |k, v| req.headers[k] = v }
          req.options.on_data = proc do |chunk, _bytes|
            @logger.debug("SSE chunk received: #{chunk.inspect}")
            process_sse_chunk(chunk.dup)
          end
        end
      rescue StandardError
        # On any SSE thread error, signal connection established to unblock connect
        @mutex.synchronize do
          @connection_established = true
          @connection_cv.broadcast
        end
      ensure
        @mutex.synchronize { @sse_connected = false }
      end
    end

    # Process an SSE chunk from the server
    # @param chunk [String] the chunk to process
    def process_sse_chunk(chunk)
      @logger.debug("Processing SSE chunk: #{chunk.inspect}")
      local_buffer = nil

      @mutex.synchronize do
        @buffer += chunk

        while (event_end = @buffer.index("\n\n"))
          event_data = @buffer.slice!(0, event_end + 2)
          local_buffer = event_data
        end
      end

      parse_and_handle_sse_event(local_buffer) if local_buffer
    end

    # Parse and handle an SSE event
    # @param event_data [String] the event data to parse
    def parse_and_handle_sse_event(event_data)
      event = parse_sse_event(event_data)
      return if event.nil?

      case event[:event]
      when 'endpoint'
        ep = event[:data]
        @mutex.synchronize do
          @rpc_endpoint = ep
          @connection_established = true
          @connection_cv.broadcast
        end
      when 'message'
        begin
          data = JSON.parse(event[:data])
          # Dispatch JSON-RPC notifications (no id, has method)
          if data['method'] && !data.key?('id')
            @notification_callback&.call(data['method'], data['params'])
            return
          end

          @mutex.synchronize do
            @tools_data = data['result']['tools'] if data['result'] && data['result']['tools']

            if data['id']
              if data['error']
                @sse_results[data['id']] = {
                  'isError' => true,
                  'content' => [{ 'type' => 'text', 'text' => data['error'].to_json }]
                }
              elsif data['result']
                @sse_results[data['id']] = data['result']
              end
            end
          end
        rescue JSON::ParserError
          nil
        end
      end
    end

    # Parse an SSE event
    # @param event_data [String] the event data to parse
    # @return [Hash, nil] the parsed event, or nil if the event is invalid
    def parse_sse_event(event_data)
      @logger.debug("Parsing SSE event data: #{event_data.inspect}")
      event = { event: 'message', data: '', id: nil }
      data_lines = []

      event_data.each_line do |line|
        line = line.chomp
        next if line.empty?

        if line.start_with?('event:')
          event[:event] = line[6..].strip
        elsif line.start_with?('data:')
          data_lines << line[5..].strip
        elsif line.start_with?('id:')
          event[:id] = line[3..].strip
        end
      end

      event[:data] = data_lines.join("\n")
      @logger.debug("Parsed SSE event: #{event.inspect}")
      event[:data].empty? ? nil : event
    end

    # Request the tools list using JSON-RPC
    # @return [Array<Hash>] the tools data
    def request_tools_list
      @mutex.synchronize do
        return @tools_data if @tools_data
      end

      request_id = @mutex.synchronize { @request_id += 1 }

      json_rpc_request = {
        jsonrpc: '2.0',
        id: request_id,
        method: 'tools/list',
        params: {}
      }

      result = send_jsonrpc_request(json_rpc_request)

      if result && result['tools']
        @mutex.synchronize do
          @tools_data = result['tools']
        end
        return @mutex.synchronize { @tools_data.dup }
      elsif result
        @mutex.synchronize do
          @tools_data = result
        end
        return @mutex.synchronize { @tools_data.dup }
      end

      raise MCPClient::Errors::ToolCallError, 'Failed to get tools list from JSON-RPC request'
    end

    # Helper: execute block with retry/backoff for transient errors
    # @yield block to execute
    # @return result of block
    def with_retry
      attempts = 0
      begin
        yield
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ServerError, IOError, Errno::ETIMEDOUT,
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

    # Send a JSON-RPC request to the server and wait for result
    # @param request [Hash] the JSON-RPC request
    # @return [Hash] the result of the request
    def send_jsonrpc_request(request)
      @logger.debug("Sending JSON-RPC request: #{request.to_json}")
      uri = URI.parse(@base_url)
      base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      rpc_ep = @mutex.synchronize { @rpc_endpoint }

      @rpc_conn ||= Faraday.new(url: base) do |f|
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.options.open_timeout = @read_timeout
        f.options.timeout = @read_timeout
        f.adapter Faraday.default_adapter
      end

      response = @rpc_conn.post(rpc_ep) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Accept'] = 'application/json'
        (@headers.dup.tap do |h|
          h.delete('Accept')
          h.delete('Cache-Control')
        end).each do |k, v|
          req.headers[k] = v
        end
        req.body = request.to_json
      end
      @logger.debug("Received JSON-RPC response: #{response.status} #{response.body}")

      unless response.success?
        raise MCPClient::Errors::ServerError, "Server returned error: #{response.status} #{response.reason_phrase}"
      end

      if @use_sse
        # Wait for result via SSE channel
        request_id = request[:id]
        start_time = Time.now
        timeout = @read_timeout || 10
        loop do
          result = nil
          @mutex.synchronize do
            result = @sse_results.delete(request_id) if @sse_results.key?(request_id)
          end
          return result if result
          break if Time.now - start_time > timeout

          sleep 0.1
        end
        raise MCPClient::Errors::ToolCallError, "Timeout waiting for SSE result for request #{request_id}"
      else
        begin
          data = JSON.parse(response.body)
          data['result']
        rescue JSON::ParserError => e
          raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
        end
      end
    end
  end
end
