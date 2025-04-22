# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCP do
  describe '.create_client' do
    it 'returns an MCP::Client instance' do
      client = MCP.create_client(mcp_server_configs: [])
      expect(client).to be_a(MCP::Client)
    end
  end

  describe '.stdio_config' do
    it 'builds a stdio server config hash' do
      cmd = 'echo hi'
      cfg = MCP.stdio_config(command: cmd)
      expect(cfg).to eq(type: 'stdio', command: cmd)
    end
  end

  describe '.sse_config' do
    it 'builds an sse server config hash with base_url and headers' do
      url = 'https://example.com/'
      headers = { 'Authorization' => 'Bearer token' }
      cfg = MCP.sse_config(base_url: url, headers: headers)
      expect(cfg).to eq(type: 'sse', base_url: url, headers: headers)
    end
  end
end
