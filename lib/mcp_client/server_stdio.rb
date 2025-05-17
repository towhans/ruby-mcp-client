# frozen_string_literal: true

require 'open3'
require 'json'
require_relative 'version'
require 'logger'

module MCPClient
  # JSON-RPC implementation of MCP server over stdio.
  class ServerStdio < ServerBase
    attr_reader :command

    # Timeout in seconds for responses
    READ_TIMEOUT = 15

    # @param command [String, Array] the stdio command to launch the MCP JSON-RPC server
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param read_timeout [Numeric] timeout in seconds for reading responses
    # @param name [String, nil] optional name for this server
    # @param logger [Logger, nil] optional logger
    def initialize(command:, retries: 0, retry_backoff: 1, read_timeout: READ_TIMEOUT, name: nil, logger: nil)
      super(name: name)
      @command = command.is_a?(Array) ? command.join(' ') : command
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @next_id = 1
      @pending = {}
      @initialized = false
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @logger.progname = self.class.name
      @logger.formatter = proc { |severity, _datetime, progname, msg| "#{severity} [#{progname}] #{msg}\n" }
      @max_retries = retries
      @retry_backoff = retry_backoff
      @read_timeout = read_timeout
    end

    # Connect to the MCP server by launching the command process via stdout/stdin
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@command)
      true
    rescue StandardError => e
      raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server: #{e.message}"
    end

    # Spawn a reader thread to collect JSON-RPC responses
    def start_reader
      @reader_thread = Thread.new do
        @stdout.each_line do |line|
          handle_line(line)
        end
      rescue StandardError
        # Reader thread aborted unexpectedly
      end
    end

    # Handle a line of output from the stdio server
    # Parses JSON-RPC messages and adds them to pending responses
    # @param line [String] line of output to parse
    def handle_line(line)
      msg = JSON.parse(line)
      @logger.debug("Received line: #{line.chomp}")
      # Dispatch JSON-RPC notifications (no id, has method)
      if msg['method'] && !msg.key?('id')
        @notification_callback&.call(msg['method'], msg['params'])
        return
      end
      # Handle standard JSON-RPC responses
      id = msg['id']
      return unless id

      @mutex.synchronize do
        @pending[id] = msg
        @cond.broadcast
      end
    rescue JSON::ParserError
      # Skip non-JSONRPC lines in the output stream
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      ensure_initialized
      req_id = next_id
      # JSON-RPC method for listing tools
      req = { 'jsonrpc' => '2.0', 'id' => req_id, 'method' => 'tools/list', 'params' => {} }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      (res.dig('result', 'tools') || []).map { |td| MCPClient::Tool.from_json(td, server: self) }
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error listing tools: #{e.message}"
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool execution
    def call_tool(tool_name, parameters)
      ensure_initialized
      req_id = next_id
      # JSON-RPC method for calling a tool
      req = {
        'jsonrpc' => '2.0',
        'id' => req_id,
        'method' => 'tools/call',
        'params' => { 'name' => tool_name, 'arguments' => parameters }
      }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      res['result']
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Clean up the server connection
    # Closes all stdio handles and terminates any running processes and threads
    def cleanup
      return unless @stdin

      @stdin.close unless @stdin.closed?
      @stdout.close unless @stdout.closed?
      @stderr.close unless @stderr.closed?
      if @wait_thread&.alive?
        Process.kill('TERM', @wait_thread.pid)
        @wait_thread.join(1)
      end
      @reader_thread&.kill
    rescue StandardError
      # Clean up resources during unexpected termination
    ensure
      @stdin = @stdout = @stderr = @wait_thread = @reader_thread = nil
    end

    private

    # Ensure the server process is started and initialized (handshake)
    def ensure_initialized
      return if @initialized

      connect
      start_reader
      perform_initialize

      @initialized = true
    end

    # Handshake: send initialize request and initialized notification
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

    def next_id
      @mutex.synchronize do
        id = @next_id
        @next_id += 1
        id
      end
    end

    def send_request(req)
      @logger.debug("Sending JSONRPC request: #{req.to_json}")
      @stdin.puts(req.to_json)
    rescue StandardError => e
      raise MCPClient::Errors::TransportError, "Failed to send JSONRPC request: #{e.message}"
    end

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
    # @param tool_name [String]
    # @param parameters [Hash]
    # @return [Enumerator]
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # Generic JSON-RPC request: send method with params and wait for result
    # @param method [String] JSON-RPC method
    # @param params [Hash] parameters for the request
    # @return [Object] result from JSON-RPC response
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
