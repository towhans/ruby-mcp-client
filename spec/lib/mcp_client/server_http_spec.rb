# frozen_string_literal: true

require 'spec_helper'
require 'mcp_client/server_http'

RSpec.describe MCPClient::ServerHTTP do
  let(:base_url) { 'http://example.com/api' }
  let(:headers) { { 'X-Test' => 'true' } }
  let(:read_timeout) { 5 }
  let(:retries) { 2 }
  let(:retry_backoff) { 0.1 }
  let(:logger) { Logger.new(StringIO.new) }
  let(:server) do
    described_class.new(
      base_url: base_url,
      headers: headers,
      read_timeout: read_timeout,
      retries: retries,
      retry_backoff: retry_backoff,
      logger: logger
    )
  end

  describe '#initialize' do
    it 'sets attributes correctly' do
      expect(server.base_url).to eq(base_url)
      expect(server.headers).to eq(headers)
      expect(server.read_timeout).to eq(read_timeout)
      expect(server.max_retries).to eq(retries)
      expect(server.retry_backoff).to eq(retry_backoff)
      expect(server.instance_variable_get(:@logger)).to eq(logger)
    end
  end

  describe '#list_tools' do
    let(:tool_data) do
      { 'name' => 't', 'description' => 'd', 'schema' => { 'type' => 'object', 'properties' => {} } }
    end

    before do
      allow(server).to receive(:send_request)
        .with(hash_including('method' => 'tools/list'))
        .and_return('tools' => [tool_data])
    end

    it 'returns an array of Tool instances' do
      tools = server.list_tools
      expect(tools).to all(be_a(MCPClient::Tool))
      expect(tools.first.name).to eq('t')
      expect(tools.first.description).to eq('d')
      expect(tools.first.schema).to eq(tool_data['schema'])
    end
  end

  describe '#call_tool' do
    let(:result_data) { { 'value' => 123 } }

    before do
      allow(server).to receive(:send_request)
        .with(hash_including('method' => 'tools/call'))
        .and_return(result_data)
    end

    it 'returns the result of the call' do
      result = server.call_tool('tool_name', { 'arg' => 1 })
      expect(result).to eq(result_data)
    end
  end

  describe '#call_tool_streaming' do
    let(:return_value) { { 'foo' => 'bar' } }
    before do
      allow(server).to receive(:call_tool).and_return(return_value)
    end

    it 'returns an Enumerator yielding the single result' do
      enum = server.call_tool_streaming('tool_name', {})
      expect(enum).to be_an(Enumerator)
      expect(enum.to_a).to eq([return_value])
    end
  end

  describe 'error handling' do
    it 'raises ServerError on HTTP error' do
      error_resp = instance_double(Net::HTTPResponse, code: '500', message: 'Err', body: '', is_a?: false)
      fake_http = instance_double(Net::HTTP)
      # Stub transport configuration methods
      allow(fake_http).to receive(:open_timeout=)
      allow(fake_http).to receive(:read_timeout=)
      allow(fake_http).to receive(:keep_alive_timeout=)
      allow(Net::HTTP).to receive(:new).and_return(fake_http)
      allow(fake_http).to receive(:post).and_return(error_resp)
      expect do
        server.send(:send_request, { 'method' => 'tools/list', 'id' => 1, 'jsonrpc' => '2.0', 'params' => {} })
      end.to raise_error(MCPClient::Errors::ServerError)
    end
  end
end
