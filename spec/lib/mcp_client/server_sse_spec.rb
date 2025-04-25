# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ServerSSE do
  let(:base_url) { 'https://example.com/mcp' }
  let(:headers) { { 'Authorization' => 'Bearer token123' } }
  let(:server) { described_class.new(base_url: base_url, headers: headers) }
  let(:tool_data) do
    {
      'name' => 'test_tool',
      'description' => 'A test tool',
      'parameters' => {
        'type' => 'object',
        'required' => ['foo'],
        'properties' => {
          'foo' => { 'type' => 'string' }
        }
      }
    }
  end

  describe '#initialize' do
    it 'normalizes the base_url without a trailing slash' do
      expect(server.base_url).to eq('https://example.com/mcp')
    end

    it 'handles base_url that already has trailing slash' do
      server = described_class.new(base_url: 'https://example.com/mcp/')
      expect(server.base_url).to eq('https://example.com/mcp')
    end
  end

  describe '#connect' do
    it 'creates a Faraday connection for the given URL' do
      # Mock the thread creation to prevent actual connection attempts
      expect(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Stub the condition variable to simulate a successful connection
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        server.instance_variable_set(:@connection_established, true)
        block.call
      end

      expect(server.connect).to eq true
    end

    it 'handles HTTPS URLs appropriately' do
      # Skip the actual connection creation by stubbing the thread creation
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Prevent the wait call from blocking
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
        block.call
      end

      # Just verify that we can connect
      uri = URI.parse(server.base_url)
      expect(uri.scheme).to eq('https')
      expect(server.connect).to be true
    end

    it 'handles HTTP URLs appropriately' do
      http_server = described_class.new(base_url: 'http://example.com/mcp/')

      # Skip the actual connection creation by stubbing the thread creation
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Prevent the wait call from blocking
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        http_server.instance_variable_set(:@connection_established, true)
        http_server.instance_variable_set(:@initialized, true)
        block.call
      end

      # Just verify that we can connect
      uri = URI.parse(http_server.base_url)
      expect(uri.scheme).to eq('http')
      expect(http_server.connect).to be true
    end

    it 'raises ConnectionError on failure' do
      # Simulate a connection failure
      allow(Thread).to receive(:new).and_raise(StandardError.new('Connection failed'))

      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Failed to connect/)
    end
  end

  describe '#list_tools' do
    before do
      # Stub initialization to avoid real SSE connection
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end
      # Disable SSE transport for testing synchronous HTTP fallback
      server.instance_variable_set(:@use_sse, false)

      # Create a Faraday connection stub to avoid real HTTP requests
      faraday_stubs = Faraday::Adapter::Test::Stubs.new
      faraday_conn = Faraday.new do |builder|
        builder.adapter :test, faraday_stubs
      end

      # Stub the Faraday response for tools/list
      faraday_stubs.post('/messages') do |env|
        if env.body.include?('tools/list')
          [200, { 'Content-Type' => 'application/json' }, { result: { tools: [tool_data] } }.to_json]
        else
          [404, {}, 'Not Found']
        end
      end

      # Set the stubbed connection
      server.instance_variable_set(:@rpc_conn, faraday_conn)
    end

    it 'connects if not already connected' do
      # Reset initialized state
      server.instance_variable_set(:@initialized, false)
      server.instance_variable_set(:@connection_established, false)

      # Mock the connection
      expect(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end

      expect(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end

      # Makes sure tools are cached
      expect(server).to receive(:request_tools_list).and_return([tool_data])

      server.list_tools
    end

    it 'returns a list of Tool objects' do
      tools = server.list_tools
      expect(tools.length).to eq(1)
      expect(tools.first).to be_a(MCPClient::Tool)
      expect(tools.first.name).to eq('test_tool')
    end

    it 'caches the tools' do
      server.list_tools
      expect(server.tools).to be_an(Array)
      expect(server.tools.first).to be_a(MCPClient::Tool)
    end

    it 'raises ToolCallError on non-success response' do
      # Create error response stub
      faraday_stubs = Faraday::Adapter::Test::Stubs.new
      faraday_conn = Faraday.new do |builder|
        builder.adapter :test, faraday_stubs
      end

      faraday_stubs.post('/messages') do |_env|
        [500, {}, 'Server Error']
      end

      server.instance_variable_set(:@rpc_conn, faraday_conn)

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Error listing tools/)
    end

    it 'raises TransportError on invalid JSON' do
      allow(server).to receive(:request_tools_list).and_raise(
        MCPClient::Errors::TransportError.new('Invalid JSON response from server: unexpected token')
      )

      expect { server.list_tools }.to raise_error(MCPClient::Errors::TransportError, /Invalid JSON response/)
    end

    it 'raises ToolCallError on other errors' do
      # Create standard error stub
      allow(server).to receive(:request_tools_list).and_raise(StandardError.new('Network failure'))
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Error listing tools/)
    end
  end

  describe '#call_tool' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { foo: 'bar' } }
    let(:result) { { 'output' => 'success' } }

    before do
      # Stub initialization to avoid real SSE connection
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end
      # Disable SSE transport for testing synchronous HTTP fallback
      server.instance_variable_set(:@use_sse, false)

      # Create a Faraday connection stub to avoid real HTTP requests
      faraday_stubs = Faraday::Adapter::Test::Stubs.new
      faraday_conn = Faraday.new do |builder|
        builder.adapter :test, faraday_stubs
      end

      # Stub the Faraday response for tools/call
      faraday_stubs.post('/messages') do |env|
        if env.body.include?('tools/call') && env.body.include?(tool_name)
          [200, { 'Content-Type' => 'application/json' }, { result: result }.to_json]
        else
          [404, {}, 'Not Found']
        end
      end

      # Set the stubbed connection
      server.instance_variable_set(:@rpc_conn, faraday_conn)
    end

    it 'connects if not already connected' do
      expect(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      server.call_tool(tool_name, parameters)
    end

    it 'makes a POST request with the tool name and parameters' do
      response = server.call_tool(tool_name, parameters)
      expect(response).to eq(result)
    end

    it 'raises ToolCallError on non-success response' do
      # Create error response stub
      faraday_stubs = Faraday::Adapter::Test::Stubs.new
      faraday_conn = Faraday.new do |builder|
        builder.adapter :test, faraday_stubs
      end

      faraday_stubs.post('/messages') do |_env|
        [500, {}, 'Server Error']
      end

      server.instance_variable_set(:@rpc_conn, faraday_conn)

      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::ToolCallError, /Error calling tool/)
    end

    it 'raises TransportError on invalid JSON' do
      allow(server).to receive(:send_jsonrpc_request).and_raise(
        MCPClient::Errors::TransportError.new('Invalid JSON response from server: unexpected token')
      )

      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::TransportError, /Invalid JSON response/)
    end

    it 'raises ToolCallError on other errors' do
      # Directly raise during send_jsonrpc_request
      allow(server).to receive(:send_jsonrpc_request).and_raise(StandardError.new('Network failure'))
      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::ToolCallError, /Error calling tool/)
    end
  end

  describe '#cleanup' do
    it 'resets all connection state and thread' do
      # Set up initial state
      server.instance_variable_set(:@sse_thread, double('thread', kill: nil))
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@tools, [double('tool')])
      server.instance_variable_set(:@session_id, 'test-session')

      # Call cleanup and verify state
      server.cleanup

      expect(server.instance_variable_get(:@sse_thread)).to be_nil
      expect(server.instance_variable_get(:@connection_established)).to be false
      expect(server.instance_variable_get(:@sse_connected)).to be false
      expect(server.instance_variable_get(:@tools)).to be_nil
      expect(server.instance_variable_get(:@session_id)).to be_nil
    end
  end

  describe '#call_tool_streaming' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { foo: 'bar' } }
    let(:result) { { 'output' => 'success' } }

    before do
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end

      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end

      stub_request(:post, "#{base_url.sub(%r{/sse/?$}, '')}/messages")
        .with(
          headers: { 'Content-Type' => 'application/json' },
          body: %r{tools/call.*#{tool_name}}
        )
        .to_return(
          status: 200,
          body: { result: result }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'returns an enumerator that yields the result of call_tool' do
      expect(server).to receive(:call_tool).with(tool_name, parameters).and_return(result)

      enumerator = server.call_tool_streaming(tool_name, parameters)
      expect(enumerator).to be_a(Enumerator)

      results = enumerator.to_a
      expect(results.size).to eq(1)
      expect(results.first).to eq(result)
    end
  end

  describe '#ping' do
    it 'delegates to rpc_request and returns the result' do
      allow(server).to receive(:rpc_request).with('ping', {}).and_return({})
      expect(server.ping).to eq({})
    end

    it 'passes parameters to rpc_request' do
      params = { foo: 'bar' }
      allow(server).to receive(:rpc_request).with('ping', params).and_return({ 'status' => 'ok' })
      expect(server.ping(params)).to eq({ 'status' => 'ok' })
    end
  end

  describe '#rpc_request' do
    before do
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end
      server.instance_variable_set(:@use_sse, false)

      # Create a Faraday connection stub to avoid real HTTP requests
      @faraday_stubs = Faraday::Adapter::Test::Stubs.new
      faraday_conn = Faraday.new do |builder|
        builder.adapter :test, @faraday_stubs
      end

      # Default successful response
      @faraday_stubs.post('/messages') do |env|
        if env.body.include?('test_method')
          [200, { 'Content-Type' => 'application/json' }, { result: { test: 'result' } }.to_json]
        else
          [404, {}, 'Not Found']
        end
      end

      server.instance_variable_set(:@rpc_conn, faraday_conn)
    end

    it 'sends a JSON-RPC request with the given method and parameters' do
      result = server.rpc_request('test_method', { param: 'value' })
      expect(result).to eq({ 'test' => 'result' })
    end

    it 'retries transient errors' do
      server.instance_variable_set(:@max_retries, 2)
      server.instance_variable_set(:@retry_backoff, 0.01) # Speed up tests

      # Create new faraday stubs that will fail then succeed
      retry_stubs = Faraday::Adapter::Test::Stubs.new
      retry_conn = Faraday.new do |builder|
        builder.adapter :test, retry_stubs
      end

      # First call fails, second succeeds
      call_count = 0
      retry_stubs.post('/messages') do |_env|
        call_count += 1
        if call_count == 1
          [500, {}, 'Server Error']
        else
          [200, { 'Content-Type' => 'application/json' }, { result: { success: true } }.to_json]
        end
      end

      server.instance_variable_set(:@rpc_conn, retry_conn)

      result = server.rpc_request('test_method', { param: 'value' })
      expect(result).to eq({ 'success' => true })
    end

    it 'gives up after max retries' do
      server.instance_variable_set(:@max_retries, 1)
      server.instance_variable_set(:@retry_backoff, 0.01) # Speed up tests

      # Create new faraday stubs that will always fail
      fail_stubs = Faraday::Adapter::Test::Stubs.new
      fail_conn = Faraday.new do |builder|
        builder.adapter :test, fail_stubs
      end

      # Always return 500 error
      fail_stubs.post('/messages') do |_env|
        [500, {}, 'Server Error']
      end

      server.instance_variable_set(:@rpc_conn, fail_conn)

      expect do
        server.rpc_request('test_method', { param: 'value' })
      end.to raise_error(MCPClient::Errors::ServerError)
    end
  end

  describe '#rpc_notify' do
    before do
      server.instance_variable_set(:@session_id, 'test_session')
      # Skip initialization in the tests
      allow(server).to receive(:ensure_initialized).and_return(true)

      # Create a Faraday mock
      @mock_conn = instance_double(Faraday::Connection)
      allow(Faraday).to receive(:new).and_return(@mock_conn)

      # Set up message endpoint
      endpoint = '/messages?sessionId=test_session'
      server.instance_variable_set(:@rpc_endpoint, endpoint)

      # Create successful response mock
      @success_response = instance_double(Faraday::Response)
      allow(@success_response).to receive(:success?).and_return(true)
      allow(@success_response).to receive(:status).and_return(200)
      allow(@success_response).to receive(:reason_phrase).and_return('OK')

      # Create error response mock
      @error_response = instance_double(Faraday::Response)
      allow(@error_response).to receive(:success?).and_return(false)
      allow(@error_response).to receive(:status).and_return(500)
      allow(@error_response).to receive(:reason_phrase).and_return('Server Error')
    end

    it 'sends a JSON-RPC notification with the given method and parameters' do
      # Set up expectations for the post request
      expect(@mock_conn).to receive(:post) do |_endpoint, &block|
        request = double('request')
        headers = {}

        # Mock the headers hash
        expect(request).to receive(:headers).at_least(:once).and_return(headers)

        # Capture the request body
        expect(request).to receive(:body=) do |body_json|
          body = JSON.parse(body_json)
          expect(body['method']).to eq('test_notify')
          expect(body['params']).to eq({ 'param' => 'value' })
        end

        # Call the block with our request mock
        block.call(request)

        # Return success response
        @success_response
      end

      server.rpc_notify('test_notify', { param: 'value' })
    end

    it 'raises TransportError when response is not successful' do
      # Set up expectation for a failed request
      expect(@mock_conn).to receive(:post).and_return(@error_response)

      expect do
        server.rpc_notify('test_notify', { param: 'value' })
      end.to raise_error(MCPClient::Errors::TransportError, /Failed to send notification/)
    end

    it 'raises TransportError on network failures' do
      # Set up expectation for a network error
      expect(@mock_conn).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection reset'))

      expect do
        server.rpc_notify('test_notify', { param: 'value' })
      end.to raise_error(MCPClient::Errors::TransportError, /Failed to send notification/)
    end
  end
end
