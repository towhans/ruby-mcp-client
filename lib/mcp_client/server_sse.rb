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
    # Ratio of close_after timeout to ping interval
    CLOSE_AFTER_PING_RATIO = 2.5

    # Default values for connection monitoring
    DEFAULT_MAX_PING_FAILURES = 3
    DEFAULT_MAX_RECONNECT_ATTEMPTS = 5

    # Reconnection backoff constants
    BASE_RECONNECT_DELAY = 0.5
    MAX_RECONNECT_DELAY = 30
    JITTER_FACTOR = 0.25

    attr_reader :base_url, :tools, :server_info, :capabilities

    # @param base_url [String] The base URL of the MCP server
    # @param headers [Hash] Additional headers to include in requests
    # @param read_timeout [Integer] Read timeout in seconds (default: 30)
    # @param ping [Integer] Time in seconds after which to send ping if no activity (default: 10)
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param name [String, nil] optional name for this server
    # @param logger [Logger, nil] optional logger
    def initialize(base_url:, headers: {}, read_timeout: 30, ping: 10,
                   retries: 0, retry_backoff: 1, name: nil, logger: nil)
      super(name: name)
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
      @ping_interval = ping
      # Set close_after to a multiple of the ping interval
      @close_after = (ping * CLOSE_AFTER_PING_RATIO).to_i

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
      @auth_error = nil
      # Whether to use SSE transport; may disable if handshake fails
      @use_sse = true

      # Time of last activity
      @last_activity_time = Time.now
      @activity_timer_thread = nil
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

      begin
        ensure_initialized

        tools_data = request_tools_list
        @mutex.synchronize do
          @tools = tools_data.map do |tool_data|
            MCPClient::Tool.from_json(tool_data, server: self)
          end
        end

        @mutex.synchronize { @tools }
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
        # Re-raise these errors directly
        # ConnectionError includes auth errors from ensure_initialized
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
    # @raise [MCPClient::Errors::ConnectionError] if server is disconnected
    def call_tool(tool_name, parameters)
      if !@connection_established || !@sse_connected
        # Try to reconnect
        @logger.debug('Connection not active, attempting to reconnect before tool call')
        cleanup
        connect
      end

      ensure_initialized

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
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      raise
    rescue JSON::ParserError => e
      raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
    rescue Errno::ECONNREFUSED => e
      raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Connect to the MCP server over HTTP/HTTPS with SSE
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      return true if @mutex.synchronize { @connection_established }

      # Check for pre-existing auth error (needed for tests)
      pre_existing_auth_error = @mutex.synchronize { @auth_error }

      begin
        # Don't reset auth error if it's pre-existing
        @mutex.synchronize { @auth_error = nil } unless pre_existing_auth_error

        start_sse_thread
        effective_timeout = [@read_timeout || 30, 30].min
        wait_for_connection(timeout: effective_timeout)
        start_activity_monitor
        true
      rescue MCPClient::Errors::ConnectionError => e
        cleanup
        # Simply pass through any ConnectionError without wrapping it again
        # This prevents duplicate error messages in the stack
        raise e
      rescue StandardError => e
        cleanup
        # Check for stored auth error first as it's more specific
        auth_error = @mutex.synchronize { @auth_error }
        raise MCPClient::Errors::ConnectionError, auth_error if auth_error

        raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
      end
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached state
    #
    # @note This method preserves ping failure and reconnection metrics between
    #   reconnection attempts, allowing the client to track failures across
    #   multiple connection attempts. This is essential for proper reconnection
    #   logic and exponential backoff.
    def cleanup
      @mutex.synchronize do
        # Set flags first before killing threads to prevent race conditions
        # where threads might check flags after they're set but before they're killed
        @connection_established = false
        @sse_connected = false
        @initialized = false # Reset initialization state for reconnection

        # Log cleanup for debugging
        @logger.debug('Cleaning up SSE connection')

        # Store threads locally to avoid race conditions
        sse_thread = @sse_thread
        activity_thread = @activity_timer_thread

        # Clear thread references first
        @sse_thread = nil
        @activity_timer_thread = nil

        # Kill threads outside the critical section
        begin
          sse_thread&.kill
        rescue StandardError => e
          @logger.debug("Error killing SSE thread: #{e.message}")
        end

        begin
          activity_thread&.kill
        rescue StandardError => e
          @logger.debug("Error killing activity thread: #{e.message}")
        end

        if @http_client
          @http_client.finish if @http_client.started?
          @http_client = nil
        end

        # Close Faraday connections if they exist
        @rpc_conn = nil
        @sse_conn = nil

        @tools = nil
        # Don't clear auth error as we need it for reporting the correct error
        # Don't reset @consecutive_ping_failures or @reconnect_attempts as they're tracked across reconnections
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

    # Ping the server to keep the connection alive
    # @return [Hash] the result of the ping request
    # @raise [MCPClient::Errors::ToolCallError] if ping times out or fails
    # @raise [MCPClient::Errors::TransportError] if there's a connection error
    # @raise [MCPClient::Errors::ServerError] if the server returns an error
    def ping
      rpc_request('ping')
    end

    private

    # Start the activity monitor thread that handles connection maintenance
    #
    # This thread is responsible for three main tasks:
    # 1. Sending pings after inactivity (@ping_interval seconds)
    # 2. Closing idle connections after prolonged inactivity (@close_after seconds)
    # 3. Automatically reconnecting after multiple ping failures
    #
    # Reconnection parameters:
    # - @consecutive_ping_failures: Counter for consecutive failed pings
    # - @max_ping_failures: Threshold to trigger reconnection (default: 3)
    # - @reconnect_attempts: Counter for reconnection attempts
    # - @max_reconnect_attempts: Maximum retry limit (default: 5)
    def start_activity_monitor
      return if @activity_timer_thread&.alive?

      @mutex.synchronize do
        @last_activity_time = Time.now
        @consecutive_ping_failures = 0
        @max_ping_failures = DEFAULT_MAX_PING_FAILURES # Reconnect after this many failures
        @reconnect_attempts = 0
        @max_reconnect_attempts = DEFAULT_MAX_RECONNECT_ATTEMPTS # Give up after this many reconnect attempts
      end

      @activity_timer_thread = Thread.new do
        activity_monitor_loop
      rescue StandardError => e
        @logger.error("Activity monitor error: #{e.message}")
      end
    end

    # Helper method to check if connection is active
    # @return [Boolean] true if connection is established and SSE is connected
    def connection_active?
      @mutex.synchronize { @connection_established && @sse_connected }
    end

    # Main activity monitoring loop
    def activity_monitor_loop
      loop do
        sleep 1 # Check every second

        # Exit if connection is not active
        unless connection_active?
          @logger.debug('Activity monitor exiting: connection no longer active')
          return
        end

        # Initialize variables if they don't exist yet
        @mutex.synchronize do
          @consecutive_ping_failures ||= 0
          @reconnect_attempts ||= 0
          @max_ping_failures ||= DEFAULT_MAX_PING_FAILURES
          @max_reconnect_attempts ||= DEFAULT_MAX_RECONNECT_ATTEMPTS
        end

        # Check if connection was closed after our check
        return unless connection_active?

        # Get time since last activity
        time_since_activity = Time.now - @last_activity_time

        # Handle inactivity closure
        if @close_after && time_since_activity >= @close_after
          @logger.info("Closing connection due to inactivity (#{time_since_activity.round(1)}s)")
          cleanup
          return
        end

        # Handle ping if needed
        next unless @ping_interval && time_since_activity >= @ping_interval
        return unless connection_active?

        # Determine if we should reconnect or ping
        if @consecutive_ping_failures >= @max_ping_failures
          attempt_reconnection
        else
          attempt_ping
        end
      end
    end

    # This section intentionally removed, as these methods were consolidated into activity_monitor_loop

    # Attempt to reconnect when consecutive pings have failed
    # @return [void]
    def attempt_reconnection
      if @reconnect_attempts < @max_reconnect_attempts
        begin
          # Calculate backoff delay with jitter to prevent thundering herd
          base_delay = BASE_RECONNECT_DELAY * (2**@reconnect_attempts)
          jitter = rand * JITTER_FACTOR * base_delay # Add randomness to prevent thundering herd
          backoff_delay = [base_delay + jitter, MAX_RECONNECT_DELAY].min

          reconnect_msg = "Attempting to reconnect (attempt #{@reconnect_attempts + 1}/#{@max_reconnect_attempts}) "
          reconnect_msg += "after #{@consecutive_ping_failures} consecutive ping failures. "
          reconnect_msg += "Waiting #{backoff_delay.round(2)}s before reconnect..."
          @logger.warn(reconnect_msg)
          sleep(backoff_delay)

          # Close existing connection
          cleanup

          # Try to reconnect
          connect
          @logger.info('Successfully reconnected after ping failures')

          # Reset counters
          @mutex.synchronize do
            @consecutive_ping_failures = 0
            @reconnect_attempts += 1
            @last_activity_time = Time.now
          end
        rescue StandardError => e
          @logger.error("Failed to reconnect after ping failures: #{e.message}")
          @mutex.synchronize { @reconnect_attempts += 1 }
        end
      else
        # We've exceeded max reconnect attempts
        @logger.error("Exceeded maximum reconnection attempts (#{@max_reconnect_attempts}). Closing connection.")
        cleanup
      end
    end

    # Attempt to ping the server
    def attempt_ping
      unless connection_active?
        @logger.debug('Skipping ping - connection not active')
        return
      end

      time_since = Time.now - @last_activity_time
      @logger.debug("Sending ping after #{time_since.round(1)}s of inactivity")

      begin
        ping
        @mutex.synchronize do
          @last_activity_time = Time.now
          @consecutive_ping_failures = 0 # Reset counter on successful ping
        end
      rescue StandardError => e
        # Check if connection is still active before counting as failure
        unless connection_active?
          @logger.debug("Ignoring ping failure - connection already closed: #{e.message}")
          return
        end
        handle_ping_failure(e)
      end
    end

    # Handle ping failure
    # @param error [StandardError] the error that occurred during ping
    def handle_ping_failure(error)
      @mutex.synchronize { @consecutive_ping_failures += 1 }
      consecutive_failures = @consecutive_ping_failures

      if consecutive_failures == 1
        # Log full error on first failure
        @logger.error("Error sending ping: #{error.message}")
      else
        # Log more concise message on subsequent failures
        error_msg = error.message.split("\n").first
        @logger.warn("Ping failed (#{consecutive_failures}/#{@max_ping_failures}): #{error_msg}")
      end
    end

    # Record activity to reset the inactivity timer
    def record_activity
      @mutex.synchronize { @last_activity_time = Time.now }
    end

    # Wait for SSE connection to be established with periodic checks
    # @param timeout [Integer] Maximum time to wait in seconds
    # @raise [MCPClient::Errors::ConnectionError] if timeout expires or auth error
    def wait_for_connection(timeout:)
      @mutex.synchronize do
        deadline = Time.now + timeout

        until @connection_established
          remaining = [1, deadline - Time.now].min
          break if remaining <= 0 || @connection_cv.wait(remaining) { @connection_established }
        end

        # Check for auth error first
        raise MCPClient::Errors::ConnectionError, @auth_error if @auth_error

        unless @connection_established
          cleanup
          # Create more specific message for timeout
          error_msg = "Failed to connect to MCP server at #{@base_url}"
          error_msg += ': Timed out waiting for SSE connection to be established'
          raise MCPClient::Errors::ConnectionError, error_msg
        end
      end
    end

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

    # Set up the SSE connection
    # @param uri [URI] The parsed base URL
    # @return [Faraday::Connection] The configured Faraday connection
    def setup_sse_connection(uri)
      sse_base = "#{uri.scheme}://#{uri.host}:#{uri.port}"

      @sse_conn ||= Faraday.new(url: sse_base) do |f|
        f.options.open_timeout = 10
        f.options.timeout = nil
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.adapter Faraday.default_adapter
      end

      # Use response handling with status check
      @sse_conn.builder.use Faraday::Response::RaiseError
      @sse_conn
    end

    # Handle authorization errors from Faraday
    # @param error [Faraday::Error] The authorization error
    # Sets the auth error state but doesn't raise the exception directly
    # This allows the main thread to handle the error in a consistent way
    def handle_sse_auth_error(error)
      error_message = "Authorization failed: HTTP #{error.response[:status]}"
      @logger.error(error_message)

      @mutex.synchronize do
        @auth_error = error_message
        @connection_established = false
        @connection_cv.broadcast
      end
      # Don't raise here - the main thread will check @auth_error and raise appropriately
    end

    # Reset connection state and signal waiting threads
    def reset_connection_state
      @mutex.synchronize do
        @connection_established = false
        @connection_cv.broadcast
      end
    end

    # Start the SSE thread to listen for events
    # This thread handles the long-lived Server-Sent Events connection
    def start_sse_thread
      return if @sse_thread&.alive?

      @sse_thread = Thread.new do
        handle_sse_connection
      end
    end

    # Handle the SSE connection in a separate method to reduce method size
    def handle_sse_connection
      uri = URI.parse(@base_url)
      sse_path = uri.request_uri
      conn = setup_sse_connection(uri)

      reset_sse_connection_state

      begin
        establish_sse_connection(conn, sse_path)
      rescue MCPClient::Errors::ConnectionError => e
        reset_connection_state
        raise e
      rescue StandardError => e
        @logger.error("SSE connection error: #{e.message}")
        reset_connection_state
      ensure
        @mutex.synchronize { @sse_connected = false }
      end
    end

    # Reset SSE connection state
    def reset_sse_connection_state
      @mutex.synchronize do
        @sse_connected = false
        @connection_established = false
      end
    end

    # Establish SSE connection with error handling
    def establish_sse_connection(conn, sse_path)
      conn.get(sse_path) do |req|
        @headers.each { |k, v| req.headers[k] = v }

        req.options.on_data = proc do |chunk, _bytes|
          process_sse_chunk(chunk.dup) if chunk && !chunk.empty?
        end
      end
    rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
      handle_sse_auth_response_error(e)
    rescue Faraday::ConnectionFailed => e
      handle_sse_connection_failed(e)
    rescue Faraday::Error => e
      handle_sse_general_error(e)
    end

    # Handle auth errors from SSE response
    def handle_sse_auth_response_error(err)
      error_status = err.response ? err.response[:status] : 'unknown'
      auth_error = "Authorization failed: HTTP #{error_status}"

      @mutex.synchronize do
        @auth_error = auth_error
        @connection_established = false
        @connection_cv.broadcast
      end
      @logger.error(auth_error)
    end

    # Handle connection failures in SSE
    def handle_sse_connection_failed(err)
      @logger.error("Failed to connect to MCP server at #{@base_url}: #{err.message}")

      @mutex.synchronize do
        @connection_established = false
        @connection_cv.broadcast
      end
      raise
    end

    # Handle general Faraday errors in SSE
    def handle_sse_general_error(err)
      @logger.error("Failed SSE connection: #{err.message}")

      @mutex.synchronize do
        @connection_established = false
        @connection_cv.broadcast
      end
      raise
    end

    # Process an SSE chunk from the server
    # @param chunk [String] the chunk to process
    def process_sse_chunk(chunk)
      @logger.debug("Processing SSE chunk: #{chunk.inspect}")

      # Only record activity for real events
      record_activity if chunk.include?('event:')

      # Check for direct JSON error responses (which aren't proper SSE events)
      if chunk.start_with?('{') && chunk.include?('"error"') &&
         (chunk.include?('Unauthorized') || chunk.include?('authentication'))
        begin
          data = JSON.parse(chunk)
          if data['error']
            error_message = data['error']['message'] || 'Unknown server error'

            @mutex.synchronize do
              @auth_error = "Authorization failed: #{error_message}"

              @connection_established = false
              @connection_cv.broadcast
            end

            raise MCPClient::Errors::ConnectionError, "Authorization failed: #{error_message}"
          end
        rescue JSON::ParserError
          # Not valid JSON, process normally
        end
      end

      event_buffers = nil
      @mutex.synchronize do
        @buffer += chunk

        # Extract all complete events from the buffer
        event_buffers = []
        while (event_end = @buffer.index("\n\n"))
          event_data = @buffer.slice!(0, event_end + 2)
          event_buffers << event_data
        end
      end

      # Process extracted events outside the mutex to avoid deadlocks
      event_buffers&.each { |event_data| parse_and_handle_sse_event(event_data) }
    end

    # Handle SSE endpoint event
    # @param data [String] The endpoint path
    def handle_endpoint_event(data)
      @mutex.synchronize do
        @rpc_endpoint = data
        @sse_connected = true
        @connection_established = true
        @connection_cv.broadcast
      end
    end

    # Check if the error represents an authorization error
    # @param error_message [String] The error message from the server
    # @param error_code [Integer, nil] The error code if available
    # @return [Boolean] True if it's an authorization error
    def authorization_error?(error_message, error_code)
      return true if error_message.include?('Unauthorized') || error_message.include?('authentication')
      return true if [401, -32_000].include?(error_code)

      false
    end

    # Handle authorization error in SSE message
    # @param error_message [String] The error message from the server
    def handle_sse_auth_error_message(error_message)
      @mutex.synchronize do
        @auth_error = "Authorization failed: #{error_message}"
        @connection_established = false
        @connection_cv.broadcast
      end

      raise MCPClient::Errors::ConnectionError, "Authorization failed: #{error_message}"
    end

    # Process error messages in SSE responses
    # @param data [Hash] The parsed SSE message data
    def process_error_in_message(data)
      return unless data['error']

      error_message = data['error']['message'] || 'Unknown server error'
      error_code = data['error']['code']

      # Handle unauthorized errors (close connection immediately)
      handle_sse_auth_error_message(error_message) if authorization_error?(error_message, error_code)

      @logger.error("Server error: #{error_message}")
      true # Error was processed
    end

    # Process JSON-RPC notifications
    # @param data [Hash] The parsed SSE message data
    # @return [Boolean] True if a notification was processed
    def process_notification(data)
      return false unless data['method'] && !data.key?('id')

      @notification_callback&.call(data['method'], data['params'])
      true
    end

    # Process JSON-RPC responses
    # @param data [Hash] The parsed SSE message data
    # @return [Boolean] True if a response was processed
    def process_response(data)
      return false unless data['id']

      @mutex.synchronize do
        # Store tools data if present
        @tools_data = data['result']['tools'] if data['result'] && data['result']['tools']

        # Store response for the waiting request
        if data['error']
          @sse_results[data['id']] = {
            'isError' => true,
            'content' => [{ 'type' => 'text', 'text' => data['error'].to_json }]
          }
        elsif data['result']
          @sse_results[data['id']] = data['result']
        end
      end

      true
    end

    # Parse and handle an SSE event
    # @param event_data [String] the event data to parse
    def parse_and_handle_sse_event(event_data)
      event = parse_sse_event(event_data)
      return if event.nil?

      case event[:event]
      when 'endpoint'
        handle_endpoint_event(event[:data])
      when 'ping'
        # Received ping event, no action needed
      when 'message'
        handle_message_event(event)
      end
    end

    # Handle a message event from SSE
    # @param event [Hash] The parsed SSE event
    def handle_message_event(event)
      return if event[:data].empty?

      begin
        data = JSON.parse(event[:data])

        # Process the message in order of precedence
        return if process_error_in_message(data)

        return if process_notification(data)

        process_response(data)
      rescue MCPClient::Errors::ConnectionError
        # Re-raise connection errors to propagate to the calling code
        raise
      rescue JSON::ParserError => e
        @logger.warn("Failed to parse JSON from event data: #{e.message}")
      rescue StandardError => e
        @logger.error("Error processing SSE event: #{e.message}")
      end
    end

    # Parse an SSE event
    # @param event_data [String] the event data to parse
    # @return [Hash, nil] the parsed event, or nil if the event is invalid
    def parse_sse_event(event_data)
      event = { event: 'message', data: '', id: nil }
      data_lines = []
      has_content = false

      event_data.each_line do |line|
        line = line.chomp
        next if line.empty?

        # Skip SSE comments (lines starting with colon)
        next if line.start_with?(':')

        has_content = true

        if line.start_with?('event:')
          event[:event] = line[6..].strip
        elsif line.start_with?('data:')
          data_lines << line[5..].strip
        elsif line.start_with?('id:')
          event[:id] = line[3..].strip
        end
      end

      event[:data] = data_lines.join("\n")

      # Return the event even if data is empty as long as we had non-comment content
      has_content ? event : nil
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
    # @raise [MCPClient::Errors::ConnectionError] if server connection is lost
    def send_jsonrpc_request(request)
      @logger.debug("Sending JSON-RPC request: #{request.to_json}")
      record_activity

      response = post_json_rpc_request(request)

      if @use_sse
        wait_for_sse_result(request)
      else
        parse_direct_response(response)
      end
    end

    # Post a JSON-RPC request to the server
    # @param request [Hash] the JSON-RPC request
    # @return [Faraday::Response] the HTTP response
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def post_json_rpc_request(request)
      uri = URI.parse(@base_url)
      base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      rpc_ep = @mutex.synchronize { @rpc_endpoint }

      @rpc_conn ||= create_json_rpc_connection(base)

      begin
        response = send_http_request(@rpc_conn, rpc_ep, request)
        record_activity

        unless response.success?
          raise MCPClient::Errors::ServerError, "Server returned error: #{response.status} #{response.reason_phrase}"
        end

        response
      rescue Faraday::ConnectionFailed => e
        raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
      end
    end

    # Create a Faraday connection for JSON-RPC
    # @param base_url [String] the base URL for the connection
    # @return [Faraday::Connection] the configured connection
    def create_json_rpc_connection(base_url)
      Faraday.new(url: base_url) do |f|
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.options.open_timeout = @read_timeout
        f.options.timeout = @read_timeout
        f.adapter Faraday.default_adapter
      end
    end

    # Send an HTTP request with the proper headers and body
    # @param conn [Faraday::Connection] the connection to use
    # @param endpoint [String] the endpoint to post to
    # @param request [Hash] the request data
    # @return [Faraday::Response] the HTTP response
    def send_http_request(conn, endpoint, request)
      response = conn.post(endpoint) do |req|
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
      response
    end

    # Wait for an SSE result to arrive
    # @param request [Hash] the original JSON-RPC request
    # @return [Hash] the result data
    # @raise [MCPClient::Errors::ConnectionError, MCPClient::Errors::ToolCallError] on errors
    def wait_for_sse_result(request)
      request_id = request[:id]
      start_time = Time.now
      timeout = @read_timeout || 10

      ensure_sse_connection_active

      wait_for_result_with_timeout(request_id, start_time, timeout)
    end

    # Ensure the SSE connection is active, reconnect if needed
    def ensure_sse_connection_active
      return if connection_active?

      @logger.warn('SSE connection is not active, reconnecting before waiting for result')
      begin
        cleanup
        connect
      rescue MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::ConnectionError, "Failed to reconnect SSE for result: #{e.message}"
      end
    end

    # Wait for a result with timeout
    # @param request_id [Integer] the request ID to wait for
    # @param start_time [Time] when the wait started
    # @param timeout [Integer] the timeout in seconds
    # @return [Hash] the result when available
    # @raise [MCPClient::Errors::ConnectionError, MCPClient::Errors::ToolCallError] on errors
    def wait_for_result_with_timeout(request_id, start_time, timeout)
      loop do
        result = check_for_result(request_id)
        return result if result

        unless connection_active?
          raise MCPClient::Errors::ConnectionError,
                'SSE connection lost while waiting for result'
        end

        time_elapsed = Time.now - start_time
        break if time_elapsed > timeout

        sleep 0.1
      end

      raise MCPClient::Errors::ToolCallError, "Timeout waiting for SSE result for request #{request_id}"
    end

    # Check if a result is available for the given request ID
    # @param request_id [Integer] the request ID to check
    # @return [Hash, nil] the result if available, nil otherwise
    def check_for_result(request_id)
      result = nil
      @mutex.synchronize do
        result = @sse_results.delete(request_id) if @sse_results.key?(request_id)
      end

      if result
        record_activity
        return result
      end

      nil
    end

    # Parse a direct (non-SSE) JSON-RPC response
    # @param response [Faraday::Response] the HTTP response
    # @return [Hash] the parsed result
    # @raise [MCPClient::Errors::TransportError] if parsing fails
    def parse_direct_response(response)
      data = JSON.parse(response.body)
      data['result']
    rescue JSON::ParserError => e
      raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
    end
  end
end
