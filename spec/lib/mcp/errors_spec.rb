# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCP::Errors do
  it 'defines MCPError and its subclasses' do
    expect(MCP::Errors::MCPError).to be < StandardError
    expect(MCP::Errors::ToolNotFound).to be < MCP::Errors::MCPError
    expect(MCP::Errors::ServerNotFound).to be < MCP::Errors::MCPError
    expect(MCP::Errors::ToolCallError).to be < MCP::Errors::MCPError
    expect(MCP::Errors::ConnectionError).to be < MCP::Errors::MCPError
    expect(MCP::Errors::ServerError).to be < MCP::Errors::MCPError
    expect(MCP::Errors::TransportError).to be < MCP::Errors::MCPError
  end
end