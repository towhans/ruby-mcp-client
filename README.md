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
- **Server-Sent Events (SSE)**: Remote MCP servers over HTTP

The core client resides in `MCPClient::Client` and provides helper methods for integrating
with popular AI services with built-in conversions:

- `to_openai_tools()` - Formats tools for OpenAI API
- `to_anthropic_tools()` - Formats tools for Anthropic Claude API

## Usage

### Basic Client Usage

```ruby
require 'mcp_client'

client = MCPClient.create_client(
  mcp_server_configs: [
    # Local stdio server
    MCPClient.stdio_config(command: 'npx -y @modelcontextprotocol/server-filesystem /home/user'),
    # Remote HTTP SSE server
    MCPClient.sse_config(
      base_url: 'https://api.example.com/sse',
      headers: { 'Authorization' => 'Bearer YOUR_TOKEN' },
      read_timeout: 30 # Optional timeout in seconds (default: 30)
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

# Clear cached tools to force fresh fetch on next list
client.clear_cache
# Clean up connections
client.cleanup
```

### Integration Examples

The repository includes examples for integrating with popular AI APIs:

#### OpenAI Integration

Ruby-MCP-Client works with both official and community OpenAI gems:

```ruby
# Using the openai/openai-ruby gem (official)
require 'mcp_client'
require 'openai'

# Create MCP client
mcp_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(
      command: %W[npx -y @modelcontextprotocol/server-filesystem #{Dir.pwd}]
    )
  ]
)

# Convert tools to OpenAI format
tools = mcp_client.to_openai_tools

# Use with OpenAI client
client = OpenAI::Client.new(api_key: ENV['OPENAI_API_KEY'])
response = client.chat.completions.create(
  model: 'gpt-4',
  messages: [
    { role: 'user', content: 'List files in current directory' }
  ],
  tools: tools
)

# Process tool calls and results
# See examples directory for complete implementation
```

```ruby
# Using the alexrudall/ruby-openai gem (community)
require 'mcp_client'
require 'openai'

# Create MCP client
mcp_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(command: 'npx @playwright/mcp@latest')
  ]
)

# Convert tools to OpenAI format
tools = mcp_client.to_openai_tools

# Use with Ruby-OpenAI client
client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
# See examples directory for complete implementation
```

#### Anthropic Integration

```ruby
require 'mcp_client'
require 'anthropic'

# Create MCP client
mcp_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(
      command: %W[npx -y @modelcontextprotocol/server-filesystem #{Dir.pwd}]
    )
  ]
)

# Convert tools to Anthropic format
claude_tools = mcp_client.to_anthropic_tools

# Use with Anthropic client
client = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])
# See examples directory for complete implementation
```

Complete examples can be found in the `examples/` directory:
- `ruby_openai_mcp.rb` - Integration with alexrudall/ruby-openai gem
- `openai_ruby_mcp.rb` - Integration with official openai/openai-ruby gem
- `ruby_anthropic_mcp.rb` - Integration with alexrudall/ruby-anthropic gem

## MCP Server Compatibility

This client works with any MCP-compatible server, including:

- [@modelcontextprotocol/server-filesystem](https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem) - File system access
- [@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp) - Browser automation
- Custom servers implementing the MCP protocol

### Server-Sent Events (SSE) Implementation

The SSE client implementation provides these key features:

- **Robust connection handling**: Properly manages HTTP/HTTPS connections with configurable timeouts
- **Thread safety**: All operations are thread-safe using monitors and synchronized access
- **Reliable error handling**: Comprehensive error handling for network issues, timeouts, and malformed responses
- **JSON-RPC over SSE**: Full implementation of JSON-RPC 2.0 over SSE transport

## Requirements

- Ruby >= 2.7.0
- No runtime dependencies

## Implementing an MCP Server

To implement a compatible MCP server you must:

- Listen on your chosen transport (JSON-RPC stdio, or HTTP SSE)
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

## License

This gem is available as open source under the [MIT License](LICENSE).

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/simonx1/ruby-mcp-client.
