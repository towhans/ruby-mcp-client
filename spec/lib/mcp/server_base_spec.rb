# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCP::ServerBase do
  let(:base_server) do
    # create an anonymous subclass without implementing abstract methods
    Class.new(MCP::ServerBase) do
      # no overrides
    end.new
  end

  describe '#connect' do
    it 'raises NotImplementedError' do
      expect { base_server.connect }.to raise_error(NotImplementedError)
    end
  end

  describe '#list_tools' do
    it 'raises NotImplementedError' do
      expect { base_server.list_tools }.to raise_error(NotImplementedError)
    end
  end

  describe '#call_tool' do
    it 'raises NotImplementedError' do
      expect { base_server.call_tool('tool', {}) }.to raise_error(NotImplementedError)
    end
  end

  describe '#cleanup' do
    it 'raises NotImplementedError' do
      expect { base_server.cleanup }.to raise_error(NotImplementedError)
    end
  end
end
