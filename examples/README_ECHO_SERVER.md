# FastMCP Echo Server Example

This directory contains a complete example of using the Ruby MCP client with a FastMCP server.

## Overview

The example includes:
- `echo_server.py`: A Python FastMCP server with multiple tools
- `echo_server_client.rb`: A Ruby client that connects to the server and demonstrates tool usage

## Quick Start

### 1. Install Dependencies

**For the Python server:**
```bash
pip install fastmcp
```

**For the Ruby client:**
```bash
# Make sure you're in the ruby-mcp-client directory
bundle install
```

### 2. Start the Server

```bash
# From the ruby-mcp-client directory
python examples/echo_server.py
```

You should see output like:
```
Starting FastMCP Echo Server...
Server will be available at: http://127.0.0.1:8000
SSE endpoint: http://127.0.0.1:8000/sse/
JSON-RPC endpoint: http://127.0.0.1:8000/messages

Available tools:
- echo: Echo back a message
- reverse: Reverse text
- uppercase: Convert to uppercase
- count_words: Count words and characters

Press Ctrl+C to stop the server
```

### 3. Run the Client

In another terminal:
```bash
# From the ruby-mcp-client directory (not the examples directory)
bundle exec ruby examples/echo_server_client.rb
```

## Available Tools

The echo server provides these tools:

| Tool | Description | Parameters |
|------|-------------|------------|
| `echo` | Echo back the provided message | `message: str` |
| `reverse` | Reverse the provided text | `text: str` |
| `uppercase` | Convert text to uppercase | `text: str` |
| `count_words` | Count words and characters in text | `text: str` |

## Example Output

When you run the client, you'll see output like:

```
🚀 Ruby MCP Client - FastMCP Echo Server Example
==================================================
📡 Connecting to FastMCP Echo Server at http://127.0.0.1:8000/sse/
✅ Connected successfully!

📋 Fetching available tools...
Found 4 tools:
  1. echo: Echo back the provided message
     Parameters: message
  2. reverse: Reverse the provided text
     Parameters: text
  3. uppercase: Convert text to uppercase
     Parameters: text
  4. count_words: Count words in the provided text
     Parameters: text

🛠️  Demonstrating tool usage:
------------------------------

1. Testing echo tool:
   Input: Hello from Ruby MCP Client!
   Output: Hello from Ruby MCP Client!

2. Testing reverse tool:
   Input: FastMCP with Ruby
   Output: ybuR htiw PCMtsaF

3. Testing uppercase tool:
   Input: mcp protocol rocks!
   Output: MCP PROTOCOL ROCKS!

4. Testing count_words tool:
   Input: The Model Context Protocol enables seamless AI integration
   Output: {"word_count"=>8, "character_count"=>58, "character_count_no_spaces"=>51}

✨ All tools tested successfully!

🧹 Cleaning up...
👋 Done!
```

## Troubleshooting

### Server Not Starting
- Make sure you have `fastmcp` installed: `pip install fastmcp`
- Check that port 8000 is available
- Try running with `python3 echo_server.py` if `python` doesn't work

### Client Connection Issues
- Ensure the server is running before starting the client
- Check that the server is accessible at `http://127.0.0.1:8000/sse/`
- Make sure you're using `bundle exec` when running the client
- If you get "cannot load such file -- faraday/follow_redirects", run `bundle install`
- Look for any error messages in the server output

### Tool Call Errors
- Verify the tool names and parameters match what the server expects
- Check the server logs for any error messages
- Ensure the JSON-RPC protocol is working correctly

## Customization

You can modify the example to:
- Add more tools to the server
- Change the server port or endpoints
- Test different parameter types
- Implement error handling scenarios
- Test with different transport types (HTTP vs SSE)

## Learn More

- [FastMCP Documentation](https://github.com/jlowin/fastmcp)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [Ruby MCP Client Documentation](../README.md)