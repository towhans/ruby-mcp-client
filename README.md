# ruby-mcp-client

This gem provides a Ruby client for the Model Context Protocol (MCP),
enabling integration with external tools and services via a standardized protocol.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby-mcp-client'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install ruby-mcp-client
```

## Overview

MCP enables AI assistants and other services to discover and invoke external tools
via different transport mechanisms:

- **Standard I/O**: Local processes implementing the MCP protocol
- **JSON-RPC over stdio**: e.g. the Playwright MCP CLI
- **Server-Sent Events (SSE)**: Remote MCP servers over HTTP

The core client resides in `MCPClient::Client` and provides helper methods for integrating
with popular AI services with built-in conversions:

- `to_openai_tools()` - Formats tools for OpenAI API
- `to_anthropic_tools()` - Formats tools for Anthropic Claude API

> **Note**: For backward compatibility, the `MCP` namespace is still available as an alias for `MCPClient`.

## Usage

### Basic Client Usage

```ruby
require 'mcp_client'

client = MCPClient.create_client(
  mcp_server_configs: [
    # Local stdio server
    MCPClient.stdio_config(command: 'python path/to/mcp_server.py'),
    # Remote HTTP SSE server
    MCPClient.sse_config(
      base_url: 'https://api.example.com/mcp',
      headers: { 'Authorization' => 'Bearer YOUR_TOKEN' }
    )
  ]
)

# List available tools
tools = client.list_tools

# Call a specific tool by name
result = client.call_tool('example_tool', { param1: 'value1', param2: 42 })

# Format tools for specific AI services
openai_tools = client.to_openai_tools
anthropic_tools = client.to_anthropic_tools

# Clean up connections
client.cleanup
```

## Implementing an MCP Server

To implement a compatible MCP server you must:

- Listen on your chosen transport (stdio, JSON-RPC stdio, or HTTP SSE)
- Respond to `list_tools` requests with a JSON list of tools
- Respond to `call_tool` requests by executing the specified tool
- Return results (or errors) in JSON format

## Tool Schema

Each tool is defined by a name, description, and a JSON Schema for its parameters:

```json
{
  "name": "example_tool",
  "description": "Does something useful",
  "schema": {
    "type": "object",
    "properties": {
      "param1": { "type": "string" },
      "param2": { "type": "number" }
    },
    "required": ["param1"]
  }
}
```

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/simonx1/ruby-mcp-client.
