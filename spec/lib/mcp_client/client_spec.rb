# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client do
  let(:mock_server) { instance_double(MCPClient::ServerBase) }
  let(:mock_tool) do
    MCPClient::Tool.new(
      name: 'test_tool',
      description: 'A test tool',
      schema: { 'type' => 'object', 'properties' => { 'param' => { 'type' => 'string' } } }
    )
  end

  before do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
  end

  describe '#initialize' do
    it 'creates servers from configs' do
      client = described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }])
      expect(client.servers).to contain_exactly(mock_server)
    end

    it 'initializes an empty tool cache' do
      client = described_class.new
      expect(client.tool_cache).to be_empty
    end
  end

  describe '#list_tools' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])
    end

    it 'returns tools from all servers' do
      tools = client.list_tools
      expect(tools).to contain_exactly(mock_tool)
    end

    it 'caches tools after first call' do
      client.list_tools
      expect(mock_server).to have_received(:list_tools).once
      client.list_tools
      expect(mock_server).to have_received(:list_tools).once
    end

    it 'refreshes tools when cache is disabled' do
      client.list_tools
      client.list_tools(cache: false)
      expect(mock_server).to have_received(:list_tools).twice
    end
  end

  describe '#call_tool' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:tool_params) { { param: 'value' } }
    let(:tool_result) { { 'result' => 'success' } }

    before do
      allow(mock_server).to receive_messages(list_tools: [mock_tool], call_tool: tool_result)
    end

    it 'calls the tool with parameters' do
      result = client.call_tool('test_tool', tool_params)
      expect(mock_server).to have_received(:call_tool).with('test_tool', tool_params)
      expect(result).to eq(tool_result)
    end

    it "raises ToolNotFound if tool doesn't exist" do
      expect { client.call_tool('nonexistent_tool', {}) }.to raise_error(MCPClient::Errors::ToolNotFound)
    end
  end

  describe '#to_openai_tools' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])
    end

    it 'converts tools to OpenAI function specs' do
      openai_tools = client.to_openai_tools
      expect(openai_tools.size).to eq(1)
      # Function object format
      expect(openai_tools.first[:type]).to eq('function')
      expect(openai_tools.first[:function][:name]).to eq('test_tool')
      expect(openai_tools.first[:function][:parameters]).to eq(mock_tool.schema)
    end
  end

  describe '#cleanup' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:cleanup)
    end

    it 'cleans up all servers' do
      client.cleanup
      expect(mock_server).to have_received(:cleanup)
    end
  end

  describe '#clear_cache' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])
    end

    it 'clears the cache and refetches tools on next call' do
      client.list_tools
      client.clear_cache
      client.list_tools
      expect(mock_server).to have_received(:list_tools).twice
    end
  end

  describe 'convenience methods: #find_tools and #find_tool' do
    let(:other_tool) do
      MCPClient::Tool.new(
        name: 'another_tool',
        description: 'Another test tool',
        schema: { 'type' => 'object', 'properties' => {} }
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool, other_tool])
    end

    it 'returns tools matching a string pattern' do
      matches = client.find_tools('test')
      expect(matches).to contain_exactly(mock_tool)
    end

    it 'returns tools matching a Regexp pattern' do
      matches = client.find_tools(/another_/)
      expect(matches).to contain_exactly(other_tool)
    end

    it 'find_tool returns the first matching tool' do
      tool = client.find_tool(/another_/)
      expect(tool).to eq(other_tool)
    end
  end
end
