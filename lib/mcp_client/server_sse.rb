# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'json'
require 'openssl'

module MCPClient
  # Implementation of MCP server that communicates via Server-Sent Events (SSE)
  # Useful for communicating with remote MCP servers over HTTP
  class ServerSSE < ServerBase
    attr_reader :base_url, :http_client, :tools

    # @param base_url [String] The base URL of the MCP server
    # @param headers [Hash] Additional headers to include in requests
    def initialize(base_url:, headers: {})
      super()
      @base_url = base_url.end_with?('/') ? base_url : "#{base_url}/"
      @headers = headers
      @http_client = nil
      @tools = nil
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      return @tools if @tools

      connect unless @http_client

      begin
        uri = URI.parse("#{@base_url}list_tools")
        request = Net::HTTP::Get.new(uri)
        @headers.each { |k, v| request[k] = v }

        response = @http_client.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise MCPClient::Errors::ServerError, "Server returned error: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)
        @tools = data['tools'].map do |tool_data|
          MCPClient::Tool.from_json(tool_data)
        end
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
      connect unless @http_client

      begin
        uri = URI.parse("#{@base_url}call_tool")
        request = Net::HTTP::Post.new(uri)
        request.content_type = 'application/json'
        @headers.each { |k, v| request[k] = v }

        request.body = {
          tool_name: tool_name,
          parameters: parameters
        }.to_json

        response = @http_client.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise MCPClient::Errors::ServerError, "Server returned error: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)
        data['result']
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      rescue StandardError => e
        raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
      end
    end

    # Connect to the MCP server over HTTP/HTTPS
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      uri = URI.parse(@base_url)
      @http_client = Net::HTTP.new(uri.host, uri.port)

      # Configure SSL if using HTTPS
      if uri.scheme == 'https'
        @http_client.use_ssl = true
        @http_client.verify_mode = OpenSSL::SSL::VERIFY_PEER
        @http_client.open_timeout = 10
        @http_client.read_timeout = 30
      end

      true
    rescue StandardError => e
      raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached tools
    def cleanup
      if @http_client
        @http_client.finish if @http_client.started?
        @http_client = nil
      end
      @tools = nil
    end
  end
end
