# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ServerFactory do
  describe '.create' do
    context 'with stdio config' do
      let(:command) { 'python test.py' }
      let(:config) { { type: 'stdio', command: command } }

      it 'creates a ServerStdio instance' do
        server = described_class.create(config)
        expect(server).to be_a(MCPClient::ServerStdio)
        expect(server.command).to eq(command)
      end

      it 'propagates the logger to the server' do
        custom_logger = Logger.new(StringIO.new)
        server = described_class.create(config, logger: custom_logger)
        expect(server.instance_variable_get(:@logger)).to eq(custom_logger)
      end
    end

    context 'with sse config' do
      let(:base_url) { 'https://example.com/mcp' }
      let(:headers) { { 'Authorization' => 'Bearer token' } }
      let(:config) { { type: 'sse', base_url: base_url, headers: headers } }

      it 'creates a ServerSSE instance' do
        server = described_class.create(config)
        expect(server).to be_a(MCPClient::ServerSSE)
        expect(server.base_url).to eq('https://example.com/mcp')
      end

      it 'propagates the logger to the server' do
        custom_logger = Logger.new(StringIO.new)
        server = described_class.create(config, logger: custom_logger)
        expect(server.instance_variable_get(:@logger)).to eq(custom_logger)
      end
    end

    context 'with config that includes logger' do
      let(:custom_logger) { Logger.new(StringIO.new) }
      let(:config) { { type: 'stdio', command: 'test', logger: custom_logger } }

      it 'uses the logger from config over the factory logger' do
        factory_logger = Logger.new(StringIO.new)
        server = described_class.create(config, logger: factory_logger)
        expect(server.instance_variable_get(:@logger)).to eq(custom_logger)
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
