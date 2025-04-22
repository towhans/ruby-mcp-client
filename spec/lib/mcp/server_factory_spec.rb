# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCP::ServerFactory do
  describe '.create' do
    context 'with stdio config' do
      let(:command) { 'python test.py' }
      let(:config) { { type: 'stdio', command: command } }

      it 'creates a ServerStdio instance' do
        server = described_class.create(config)
        expect(server).to be_a(MCP::ServerStdio)
        expect(server.command).to eq(command)
      end
    end

    context 'with sse config' do
      let(:base_url) { 'https://example.com/mcp' }
      let(:headers) { { 'Authorization' => 'Bearer token' } }
      let(:config) { { type: 'sse', base_url: base_url, headers: headers } }

      it 'creates a ServerSSE instance' do
        server = described_class.create(config)
        expect(server).to be_a(MCP::ServerSSE)
        expect(server.base_url).to eq('https://example.com/mcp/')
      end
    end

    context 'with unknown type' do
      let(:config) { { type: 'unknown' } }

      it 'raises an ArgumentError' do
        expect { described_class.create(config) }.to raise_error(ArgumentError, /Unknown server type/)
      end
    end
  end
end
