# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MCP compatibility' do
  it 'maintains MCP namespace for backward compatibility' do
    expect(MCP::VERSION).to eq(MCPClient::VERSION)
    expect(MCP.create_client).to be_a(MCPClient::Client)
    expect(MCP.create_client).to be_a(MCP::Client)

    # Test class aliases
    expect(MCP::Errors).to eq(MCPClient::Errors)
    expect(MCP::Tool).to eq(MCPClient::Tool)
    expect(MCP::Client).to eq(MCPClient::Client)
    expect(MCP::ServerBase).to eq(MCPClient::ServerBase)
    expect(MCP::ServerStdio).to eq(MCPClient::ServerStdio)
    expect(MCP::ServerSSE).to eq(MCPClient::ServerSSE)
    expect(MCP::ServerFactory).to eq(MCPClient::ServerFactory)

    # Test error classes
    expect(MCP::Errors::MCPError).to eq(MCPClient::Errors::MCPError)
    expect(MCP::Errors::ToolNotFound).to eq(MCPClient::Errors::ToolNotFound)
    expect(MCP::Errors::ServerNotFound).to eq(MCPClient::Errors::ServerNotFound)
    expect(MCP::Errors::ToolCallError).to eq(MCPClient::Errors::ToolCallError)
    expect(MCP::Errors::ConnectionError).to eq(MCPClient::Errors::ConnectionError)
    expect(MCP::Errors::ServerError).to eq(MCPClient::Errors::ServerError)
    expect(MCP::Errors::TransportError).to eq(MCPClient::Errors::TransportError)
  end

  it 'allows MCP methods to proxy to MCPClient' do
    # Test that method_missing in MCP forwards to MCPClient
    expect(MCP.stdio_config(command: 'test')).to eq(MCPClient.stdio_config(command: 'test'))
    expect(MCP.sse_config(base_url: 'http://example.com')).to eq(MCPClient.sse_config(base_url: 'http://example.com'))
  end
end
