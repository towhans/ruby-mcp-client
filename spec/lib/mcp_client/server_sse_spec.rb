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

    it 'initializes auth_error to nil' do
      expect(server.instance_variable_get(:@auth_error)).to be_nil
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

    it 'preserves authorization error messages' do
      # Set an authorization error
      server.instance_variable_set(:@auth_error, 'Authorization failed: Invalid token')

      # Simulate a connection failure
      allow(Thread).to receive(:new).and_raise(StandardError.new('Connection failed'))

      # Should use the auth error message instead of the generic connection message
      expect do
        server.connect
      end.to raise_error(MCPClient::Errors::ConnectionError, 'Authorization failed: Invalid token')
    end

    it 'preserves authorization errors from ConnectionError exceptions' do
      # Simulate a connection failure with authorization error message
      allow(Thread).to receive(:new).and_raise(
        MCPClient::Errors::ConnectionError.new('Authorization failed: Unauthorized request')
      )

      # Should preserve the authorization error message
      expect do
        server.connect
      end.to raise_error(MCPClient::Errors::ConnectionError, 'Authorization failed: Unauthorized request')
    end

    it 'times out if connection is not established' do
      # Mock the thread with proper behavior
      thread_double = double('thread', alive?: true)
      allow(thread_double).to receive(:kill)
      allow(Thread).to receive(:new).and_return(thread_double)

      # Set a short timeout for the test
      server.instance_variable_set(:@read_timeout, 0.1)

      # Reset connection state
      server.instance_variable_set(:@connection_established, false)

      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Timed out waiting/)
    end

    it 'waits with periodic checks until connection is established' do
      # Mock the thread creation to prevent actual connection attempts
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Set up a counter to track wait calls
      wait_count = 0

      # Stub the condition variable to set connection_established only after multiple waits
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        wait_count += 1
        if wait_count >= 3
          server.instance_variable_set(:@connection_established, true)
          block.call
        else
          false
        end
      end

      expect(server.connect).to eq true
      expect(wait_count).to eq 3
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

      server.instance_variable_set(:@rpc_endpoint, '/rpc')

      # Stub the Faraday response for tools/list
      faraday_stubs.post('/rpc') do |env|
        request_body = JSON.parse(env.body)
        if request_body['method'] == 'tools/list'
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

      server.instance_variable_set(:@rpc_endpoint, '/rpc')

      # Stub the Faraday response for tools/call
      faraday_stubs.post('/rpc') do |env|
        request_body = JSON.parse(env.body)
        if request_body['method'] == 'tools/call' && request_body['params']['name'] == tool_name
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

      # Call cleanup and verify state
      server.cleanup

      expect(server.instance_variable_get(:@sse_thread)).to be_nil
      expect(server.instance_variable_get(:@connection_established)).to be false
      expect(server.instance_variable_get(:@sse_connected)).to be false
      expect(server.instance_variable_get(:@tools)).to be_nil
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
      allow(server).to receive(:rpc_request).with('ping').and_return({})
      expect(server.ping).to eq({})
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

      server.instance_variable_set(:@rpc_endpoint, '/rpc')
      @faraday_stubs.post('/rpc') do |env|
        request_body = JSON.parse(env.body)
        if request_body['method'] == 'test_method'
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
      retry_stubs.post('/rpc') do |_env|
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
      fail_stubs.post('/rpc') do |_env|
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

  describe '#parse_sse_event' do
    it 'parses event data correctly' do
      event_data = "event: endpoint\ndata: /messages\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event).to be_a(Hash)
      expect(event[:event]).to eq('endpoint')
      expect(event[:data]).to eq('/messages')
    end

    it 'handles empty data in events' do
      event_data = "event: ping\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event).to be_a(Hash)
      expect(event[:event]).to eq('ping')
      expect(event[:data]).to eq('')
    end

    it 'skips comment lines' do
      event_data = ": This is a comment\nevent: message\ndata: actual data\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event[:event]).to eq('message')
      expect(event[:data]).to eq('actual data')
    end

    it 'returns nil for comment-only events' do
      event_data = ": keep-alive 1\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event).to be_nil
    end

    it 'handles multi-line data' do
      event_data = "event: message\ndata: line 1\ndata: line 2\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event[:event]).to eq('message')
      expect(event[:data]).to eq("line 1\nline 2")
    end
  end

  describe '#process_sse_chunk' do
    it 'processes multiple events in a single chunk' do
      chunk = "event: endpoint\ndata: /messages\n\nevent: message\ndata: {\"id\":1}\n\n"

      # Expect parse_and_handle_sse_event to be called twice, once for each event
      expect(server).to receive(:parse_and_handle_sse_event).twice

      server.send(:process_sse_chunk, chunk)
    end

    it 'accumulates partial chunks' do
      # Send a partial chunk first
      partial_chunk = "event: endpoint\ndata: /messages"
      server.send(:process_sse_chunk, partial_chunk)

      # Complete the event with a second chunk
      completion_chunk = "\n\n"

      # Expect parse_and_handle_sse_event to be called once when the event is complete
      expect(server).to receive(:parse_and_handle_sse_event).once

      server.send(:process_sse_chunk, completion_chunk)
    end

    it 'detects direct JSON-RPC error responses with authorization errors' do
      # Authorization error in JSON-RPC format that isn't an SSE event
      error_response = '{
        "jsonrpc":"2.0",
        "error":{"code":-32000,"message":"Unauthorized: Invalid token"},
        "id":null
      }'

      # Should set auth_error and raise ConnectionError
      expect do
        server.send(:process_sse_chunk, error_response)
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)

      # Check auth_error was set
      expect(server.instance_variable_get(:@auth_error)).to match(/Authorization failed/)
    end

    it 'ignores invalid JSON' do
      # Invalid JSON that looks like it might contain an error
      invalid_json = '{ "error": {'

      # Should not raise an error
      expect do
        server.send(:process_sse_chunk, invalid_json)
      end.not_to raise_error
    end
  end

  describe '#parse_and_handle_sse_event' do
    it 'handles endpoint events' do
      event_data = "event: endpoint\ndata: /messages\n\n"

      # Set initial state
      server.instance_variable_set(:@connection_established, false)

      server.send(:parse_and_handle_sse_event, event_data)

      # Verify the state changes
      expect(server.instance_variable_get(:@connection_established)).to eq(true)
      expect(server.instance_variable_get(:@rpc_endpoint)).to eq('/messages')
    end

    it 'handles empty message events' do
      event_data = "event: message\ndata: \n\n"

      # Should not raise an error
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.not_to raise_error
    end

    it 'handles JSON-RPC notification messages' do
      notification = { method: 'test_notification', params: { foo: 'bar' } }
      event_data = "event: message\ndata: #{notification.to_json}\n\n"

      # Set up notification callback
      notification_received = false
      server.on_notification do |method, params|
        notification_received = true
        expect(method).to eq('test_notification')
        expect(params).to eq({ 'foo' => 'bar' })
      end

      server.send(:parse_and_handle_sse_event, event_data)
      expect(notification_received).to be true
    end

    it 'handles invalid JSON gracefully' do
      event_data = "event: message\ndata: {invalid json}\n\n"

      # Should log warning but not raise
      expect(server.instance_variable_get(:@logger)).to receive(:warn)

      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.not_to raise_error
    end

    it 'detects and handles authorization errors in message events' do
      # Create a JSON-RPC error response with authorization error
      error_data = {
        jsonrpc: '2.0',
        error: {
          code: -32_000,
          message: 'Unauthorized: Invalid API token'
        },
        id: 1
      }
      event_data = "event: message\ndata: #{error_data.to_json}\n\n"

      # Should set auth_error and raise ConnectionError
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)

      # Check auth_error was set
      expect(server.instance_variable_get(:@auth_error)).to match(/Authorization failed/)
      expect(server.instance_variable_get(:@connection_established)).to be false
    end

    it 'detects authorization errors with specific error codes' do
      # Create a JSON-RPC error response with 401 error code
      error_data = {
        jsonrpc: '2.0',
        error: {
          code: 401,
          message: 'Authentication required'
        },
        id: 1
      }
      event_data = "event: message\ndata: #{error_data.to_json}\n\n"

      # Should set auth_error and raise ConnectionError
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)

      # Check auth_error was set
      expect(server.instance_variable_get(:@auth_error)).to match(/Authorization failed: Authentication required/)
    end

    it 'handles regular error messages without raising ConnectionError' do
      # Create a JSON-RPC error response with a normal error
      error_data = {
        jsonrpc: '2.0',
        error: {
          code: -32_603,
          message: 'Internal server error'
        },
        id: 1
      }
      event_data = "event: message\ndata: #{error_data.to_json}\n\n"

      # Should log the error but not raise ConnectionError
      expect(server.instance_variable_get(:@logger)).to receive(:error).with(/Server error/)

      # Should not raise an error
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.not_to raise_error

      # Should not set auth_error
      expect(server.instance_variable_get(:@auth_error)).to be_nil
    end
  end
end
