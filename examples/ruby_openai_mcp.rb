#!/usr/bin/env ruby
# frozen_string_literal: true

# MCPClient integration example using the alexrudall/ruby-openai gem
# MCP server command:
#  npx @playwright/mcp@latest --port 8931
require_relative '../lib/mcp_client'
require 'openai'
require 'json'

# Ensure the OPENAI_API_KEY environment variable is set
api_key = ENV.fetch('OPENAI_API_KEY', nil)
abort 'Please set OPENAI_API_KEY' unless api_key

# Create an MCPClient client (SSE server for demo)
mcp_client = MCPClient.create_client(
  mcp_server_configs: [MCPClient.sse_config(base_url: 'http://localhost:8931/sse')]
)

# Initialize the Ruby-OpenAI client
client = OpenAI::Client.new(access_token: api_key)

tools = mcp_client.to_openai_tools

# Build initial chat messages
messages = [
  { role: 'system', content: 'You are a helpful assistant' },
  { role: 'user', content: 'Open google.com website and search for DAO' }
]

# 1) Send chat with function definitions
response = client.chat(
  parameters: {
    model: 'gpt-4.1-mini',
    messages: messages,
    tools: tools
  }
)

# Extract the function call from the response
tool_call = response.dig('choices', 0, 'message', 'tool_calls', 0)

# 2) Invoke the MCPClient tool
function_details = tool_call['function']
name = function_details['name']
args = JSON.parse(function_details['arguments'])
result = mcp_client.call_tool(name, args)

# 3) Add function call + result to conversation
messages << { role: 'assistant', tool_calls: [tool_call] }
messages << { role: 'tool', tool_call_id: tool_call['id'], name: name, content: result.to_json }

# 4) Get the first response from the model
response = client.chat(
  parameters: {
    model: 'gpt-4.1-mini',
    messages: messages,
    tools: tools
  }
)

# Extract the function call from the response
tool_call = response.dig('choices', 0, 'message', 'tool_calls', 0)

# 5) Invoke the next MCPClient tool
function_details = tool_call['function']
name = function_details['name']
args = JSON.parse(function_details['arguments'])
result = mcp_client.call_tool(name, args)

# 6) Add function call + result to conversation
messages << { role: 'assistant', tool_calls: [tool_call] }
messages << { role: 'tool', tool_call_id: tool_call['id'], name: name, content: result.to_json }

# 7) Get final response from the model
final = client.chat(
  parameters: {
    model: 'gpt-4.1-mini',
    messages: messages,
    tools: tools
  }
)

puts final.dig('choices', 0, 'message', 'content')

sleep 5
