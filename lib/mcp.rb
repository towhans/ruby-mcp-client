# frozen_string_literal: true

# Load the main module
require_relative "mcp_client"

# This module exists for backward compatibility with code that used MCP instead of MCPClient
module MCP
  # Forward all class methods to MCPClient
  def self.method_missing(method_name, *args, **kwargs, &block)
    if MCPClient.respond_to?(method_name)
      MCPClient.send(method_name, *args, **kwargs, &block)
    else
      super
    end
  end

  # Make sure respond_to? is consistent with method_missing
  def self.respond_to_missing?(method_name, include_private = false)
    MCPClient.respond_to?(method_name) || super
  end

  # VERSION needs to be accessible directly
  VERSION = MCPClient::VERSION

  # Define aliases for all the classes
  Errors = MCPClient::Errors
  Tool = MCPClient::Tool
  Client = MCPClient::Client
  ServerBase = MCPClient::ServerBase
  ServerStdio = MCPClient::ServerStdio
  ServerSSE = MCPClient::ServerSSE
  ServerFactory = MCPClient::ServerFactory

  # Make error classes available through the MCP namespace
  module Errors
    # Use constant_missing to delegate to MCPClient::Errors
    def self.const_missing(name)
      if MCPClient::Errors.const_defined?(name)
        MCPClient::Errors.const_get(name)
      else
        super
      end
    end
  end
end