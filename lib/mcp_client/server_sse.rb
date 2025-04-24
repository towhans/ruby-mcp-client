# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'json'
require 'openssl'
require 'monitor'
require 'logger'

module MCPClient
  # Implementation of MCP server that communicates via Server-Sent Events (SSE)
  # Useful for communicating with remote MCP servers over HTTP
  class ServerSSE < ServerBase
    attr_reader :base_url, :tools, :session_id, :http_client, :server_info, :capabilities

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
      @base_url = base_url.end_with?('/') ? base_url : "#{base_url}/"
      @headers = headers.merge({
                                 'Accept' => 'text/event-stream',
                                 'Cache-Control' => 'no-cache',
                                 'Connection' => 'keep-alive'
                               })
      @http_client = nil
      @tools = nil
      @read_timeout = read_timeout
      @session_id = nil
      @tools_data = nil
      @request_id = 0
      @sse_results = {}
      @mutex = Monitor.new
      @buffer = ''
      @sse_connected = false
      @connection_established = false
      @connection_cv = @mutex.new_cond
      @initialized = false
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

        uri = URI.parse(@base_url)
        @http_client = Net::HTTP.new(uri.host, uri.port)

        if uri.scheme == 'https'
          @http_client.use_ssl = true
          @http_client.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end

        @http_client.open_timeout = 10
        @http_client.read_timeout = @read_timeout
        @http_client.keep_alive_timeout = 60

        @http_client.start
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
        @session_id = nil
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
      url_base = @base_url.sub(%r{/sse/?$}, '')
      uri = URI.parse("#{url_base}/messages?sessionId=#{@session_id}")
      rpc_http = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == 'https'
        rpc_http.use_ssl = true
        rpc_http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
      rpc_http.open_timeout = 10
      rpc_http.read_timeout = @read_timeout
      rpc_http.keep_alive_timeout = 60
      rpc_http.start do |http|
        http_req = Net::HTTP::Post.new(uri)
        http_req.content_type = 'application/json'
        http_req.body = { jsonrpc: '2.0', method: method, params: params }.to_json
        headers = @headers.dup
        headers.except('Accept', 'Cache-Control').each { |k, v| http_req[k] = v }
        response = http.request(http_req)
        unless response.is_a?(Net::HTTPSuccess)
          raise MCPClient::Errors::ServerError, "Notification failed: #{response.code} #{response.message}"
        end
      end
    rescue StandardError => e
      raise MCPClient::Errors::TransportError, "Failed to send notification: #{e.message}"
    ensure
      rpc_http.finish if rpc_http&.started?
    end

    private

    # Ensure handshake initialization has been performed
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
        sse_http = nil
        begin
          uri = URI.parse(@base_url)
          sse_http = Net::HTTP.new(uri.host, uri.port)

          if uri.scheme == 'https'
            sse_http.use_ssl = true
            sse_http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          end

          sse_http.open_timeout = 10
          sse_http.read_timeout = @read_timeout
          sse_http.keep_alive_timeout = 60

          sse_http.start do |http|
            request = Net::HTTP::Get.new(uri)
            @headers.each { |k, v| request[k] = v }

            http.request(request) do |response|
              unless response.is_a?(Net::HTTPSuccess) && response['content-type']&.start_with?('text/event-stream')
                @mutex.synchronize do
                  @connection_established = false
                  @connection_cv.broadcast
                end
                raise MCPClient::Errors::ServerError, 'Server response not OK or not text/event-stream'
              end

              @mutex.synchronize do
                @sse_connected = true
              end

              response.read_body do |chunk|
                @logger.debug("SSE chunk received: #{chunk.inspect}")
                process_sse_chunk(chunk.dup)
              end
            end
          end
        rescue StandardError
          nil
        ensure
          sse_http&.finish if sse_http&.started?
          @mutex.synchronize do
            @sse_connected = false
          end
        end
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
        if event[:data].include?('sessionId=')
          session_id = event[:data].split('sessionId=').last

          @mutex.synchronize do
            @session_id = session_id
            @connection_established = true
            @connection_cv.broadcast
          end
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
      rpc_http = Net::HTTP.new(uri.host, uri.port)

      if uri.scheme == 'https'
        rpc_http.use_ssl = true
        rpc_http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      rpc_http.open_timeout = 10
      rpc_http.read_timeout = @read_timeout
      rpc_http.keep_alive_timeout = 60

      begin
        rpc_http.start do |http|
          session_id = @mutex.synchronize { @session_id }

          url = if session_id
                  "#{@base_url.sub(%r{/sse/?$}, '')}/messages?sessionId=#{session_id}"
                else
                  "#{@base_url.sub(%r{/sse/?$}, '')}/messages"
                end

          uri = URI.parse(url)
          http_request = Net::HTTP::Post.new(uri)
          http_request.content_type = 'application/json'
          http_request.body = request.to_json

          headers = @mutex.synchronize { @headers.dup }
          headers.except('Accept', 'Cache-Control')
                 .each { |k, v| http_request[k] = v }

          response = http.request(http_request)
          @logger.debug("Received JSON-RPC response: #{response.code} #{response.body}")

          unless response.is_a?(Net::HTTPSuccess)
            raise MCPClient::Errors::ServerError, "Server returned error: #{response.code} #{response.message}"
          end

          if response.code == '202'
            request_id = request[:id]

            start_time = Time.now
            timeout = 10
            result = nil

            loop do
              @mutex.synchronize do
                if @sse_results[request_id]
                  result = @sse_results[request_id]
                  @sse_results.delete(request_id)
                end
              end

              break if result || (Time.now - start_time > timeout)

              sleep 0.1
            end

            return result if result

            raise MCPClient::Errors::ToolCallError, "Timeout waiting for SSE result for request #{request_id}"

          else
            begin
              data = JSON.parse(response.body)
              return data['result']
            rescue JSON::ParserError => e
              raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
            end
          end
        end
      ensure
        rpc_http.finish if rpc_http.started?
      end
    end
  end
end
