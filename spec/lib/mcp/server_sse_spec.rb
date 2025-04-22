# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCP::ServerSSE do
  let(:base_url) { 'https://example.com/mcp/' }
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
    it 'sets the base_url with trailing slash' do
      expect(server.base_url).to eq('https://example.com/mcp/')
    end

    it 'handles base_url that already has trailing slash' do
      server = described_class.new(base_url: 'https://example.com/mcp/')
      expect(server.base_url).to eq('https://example.com/mcp/')
    end
  end

  describe '#connect' do
    it 'creates an HTTP client for the given URL' do
      server.connect
      expect(server.http_client).to be_a(Net::HTTP)
      expect(server.http_client.address).to eq('example.com')
      expect(server.http_client.port).to eq(443)
    end

    it 'configures SSL for HTTPS URLs' do
      server.connect
      expect(server.http_client.use_ssl?).to be true
      expect(server.http_client.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
    end

    it 'does not configure SSL for HTTP URLs' do
      http_server = described_class.new(base_url: 'http://example.com/mcp/')
      http_server.connect
      expect(http_server.http_client.use_ssl?).to be false
    end

    it 'raises ConnectionError on failure' do
      allow(Net::HTTP).to receive(:new).and_raise(StandardError.new('Connection failed'))
      expect { server.connect }.to raise_error(MCP::Errors::ConnectionError, /Failed to connect/)
    end
  end

  describe '#list_tools' do
    before do
      stub_request(:get, "#{base_url}list_tools")
        .with(headers: headers)
        .to_return(
          status: 200,
          body: { tools: [tool_data] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'connects if not already connected' do
      expect(server).to receive(:connect).and_call_original
      server.list_tools
    end

    it 'returns a list of Tool objects' do
      tools = server.list_tools
      expect(tools.length).to eq(1)
      expect(tools.first).to be_a(MCP::Tool)
      expect(tools.first.name).to eq('test_tool')
    end

    it 'caches the tools' do
      server.list_tools
      expect(server.tools).to be_an(Array)
      expect(server.tools.first).to be_a(MCP::Tool)
    end

    it 'raises ToolCallError on non-success response' do
      stub_request(:get, "#{base_url}list_tools")
        .with(headers: headers)
        .to_return(status: 500, body: 'Server Error')

      expect { server.list_tools }.to raise_error(MCP::Errors::ToolCallError, /Error listing tools/)
    end

    it 'raises TransportError on invalid JSON' do
      stub_request(:get, "#{base_url}list_tools")
        .with(headers: headers)
        .to_return(
          status: 200,
          body: 'Invalid JSON',
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { server.list_tools }.to raise_error(MCP::Errors::TransportError, /Invalid JSON response/)
    end

    it 'raises ToolCallError on other errors' do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(StandardError.new('Network failure'))
      expect { server.list_tools }.to raise_error(MCP::Errors::ToolCallError, /Error listing tools/)
    end
  end

  describe '#call_tool' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { foo: 'bar' } }
    let(:result) { { 'output' => 'success' } }

    before do
      stub_request(:post, "#{base_url}call_tool")
        .with(
          headers: headers.merge('Content-Type' => 'application/json'),
          body: { tool_name: tool_name, parameters: parameters }.to_json
        )
        .to_return(
          status: 200,
          body: { result: result }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'connects if not already connected' do
      expect(server).to receive(:connect).and_call_original
      server.call_tool(tool_name, parameters)
    end

    it 'makes a POST request with the tool name and parameters' do
      response = server.call_tool(tool_name, parameters)
      expect(response).to eq(result)
    end

    it 'raises ToolCallError on non-success response' do
      stub_request(:post, "#{base_url}call_tool")
        .with(
          headers: headers.merge('Content-Type' => 'application/json'),
          body: { tool_name: tool_name, parameters: parameters }.to_json
        )
        .to_return(status: 500, body: 'Server Error')

      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCP::Errors::ToolCallError, /Error calling tool/)
    end

    it 'raises TransportError on invalid JSON' do
      stub_request(:post, "#{base_url}call_tool")
        .with(
          headers: headers.merge('Content-Type' => 'application/json'),
          body: { tool_name: tool_name, parameters: parameters }.to_json
        )
        .to_return(
          status: 200,
          body: 'Invalid JSON',
          headers: { 'Content-Type' => 'application/json' }
        )

      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCP::Errors::TransportError, /Invalid JSON response/)
    end

    it 'raises ToolCallError on other errors' do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(StandardError.new('Network failure'))
      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCP::Errors::ToolCallError, /Error calling tool/)
    end
  end

  describe '#cleanup' do
    it 'resets the HTTP client' do
      server.connect
      expect(server.http_client).not_to be_nil
      server.cleanup
      expect(server.http_client).to be_nil
    end
  end
end
