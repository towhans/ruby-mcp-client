# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'json'
require 'openssl'
require 'logger'

module MCPClient
  # Implementation of MCP server over HTTP JSON-RPC
  class ServerHTTP < ServerBase
    attr_reader :base_url, :headers, :read_timeout, :max_retries, :retry_backoff, :logger

    # @param base_url [String] The base URL of the MCP HTTP server
    # @param headers [Hash] HTTP headers to include in requests
    # @param read_timeout [Integer] Read timeout in seconds
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param logger [Logger, nil] optional logger
    def initialize(base_url:, headers: {}, read_timeout: 30, retries: 0, retry_backoff: 1, logger: nil)
      super()
      @base_url = base_url
      @headers = headers
      @read_timeout = read_timeout
      @max_retries = retries
      @retry_backoff = retry_backoff
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @request_id = 0
    end

    # List available tools
    # @return [Array<MCPClient::Tool>]
    def list_tools
      request_json = jsonrpc_request('tools/list', {})
      result = send_request(request_json)
      (result['tools'] || []).map { |td| MCPClient::Tool.from_json(td) }
    rescue MCPClient::Errors::MCPError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error listing tools: #{e.message}"
    end

    # Call a tool with given parameters
    # @param tool_name [String]
    # @param parameters [Hash]
    # @return [Object] result of invocation
    def call_tool(tool_name, parameters)
      request_json = jsonrpc_request('tools/call', { 'name' => tool_name, 'arguments' => parameters })
      send_request(request_json)
    rescue MCPClient::Errors::MCPError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Streaming is not supported over simple HTTP transport; fallback to single response
    # @param tool_name [String]
    # @param parameters [Hash]
    # @return [Enumerator]
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    private

    def jsonrpc_request(method, params)
      @request_id += 1
      {
        'jsonrpc' => '2.0',
        'id' => @request_id,
        'method' => method,
        'params' => params
      }
    end

    def send_request(request)
      attempts = 0
      begin
        attempts += 1
        uri = URI.parse(base_url)
        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end
        http.open_timeout = 10
        http.read_timeout = read_timeout

        @logger.debug("Sending HTTP JSONRPC request: #{request.to_json}")
        response = http.post(uri.path, request.to_json, default_headers)
        @logger.debug("Received HTTP response: #{response.code} #{response.body}")

        unless response.is_a?(Net::HTTPSuccess)
          raise MCPClient::Errors::ServerError, "Server returned error: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)
        raise MCPClient::Errors::ServerError, data['error']['message'] if data['error']

        data['result']
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError, IOError, Timeout::Error => e
        raise unless attempts <= max_retries

        delay = retry_backoff * (2**(attempts - 1))
        @logger.debug("Retry attempt #{attempts} after error: #{e.message}, sleeping #{delay}s")
        sleep(delay)
        retry
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response: #{e.message}"
      end
    end

    def default_headers
      h = headers.dup
      h['Content-Type'] = 'application/json'
      h
    end
  end
end
