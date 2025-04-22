# frozen_string_literal: true

module MCP
  # Base class for MCP servers - serves as the interface for different server implementations
  class ServerBase
    # Initialize a connection to the MCP server
    # @return [Boolean] true if connection successful
    def connect
      raise NotImplementedError, "Subclasses must implement connect"
    end

    # List all tools available from the MCP server
    # @return [Array<MCP::Tool>] list of available tools
    def list_tools
      raise NotImplementedError, "Subclasses must implement list_tools"
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    def call_tool(tool_name, parameters)
      raise NotImplementedError, "Subclasses must implement call_tool"
    end

    # Clean up the server connection
    def cleanup
      raise NotImplementedError, "Subclasses must implement cleanup"
    end
  end
end
