#!/usr/bin/env ruby
# frozen_string_literal: true
# MCP integration example using the alexrudall/ruby-anthropic gem
require_relative '../lib/mcp'
require 'anthropic'
require 'json'

# Ensure the ANTHROPIC_API_KEY environment variable is set
api_key = ENV['ANTHROPIC_API_KEY']
abort "Please set ANTHROPIC_API_KEY" unless api_key

# Create an MCP client (stdio stub for demo)
mcp_client = MCP.create_client(
  mcp_server_configs: [
    MCP.stdio_config(
      command: %W[npx -y @modelcontextprotocol/server-filesystem #{Dir.pwd}]
    )
  ]
)

# Initialize the Anthropic client
client = Anthropic::Client.new(access_token: api_key)

# Get MCP tools
mcp_tools = mcp_client.list_tools

# Convert MCP tools to Claude tool format
claude_tools = mcp_client.to_anthropic_tools

# Build initial chat messages
messages = [
  { role: "user", content: "List all files in current directory" }
]

# 1) Send messages with tool definitions
puts "Sending request with tools..."
response = client.messages(
  parameters: {
    model: "claude-3-7-sonnet-20250219",
    messages: messages,
    system: "You can call filesystem tools.",
    tools: claude_tools,
    max_tokens: 1000
  }
)
puts "Response received!"

# Extract the tool use from the response
# Claude often puts a text message first, then the tool_use in a later content item
tool_use = nil
response["content"].each do |content_item|
  if content_item["type"] == "tool_use"
    tool_use = content_item
    break
  end
end

unless tool_use
  puts "No tool use in response:"
  puts JSON.pretty_generate(response)
  exit 1
end

name = tool_use["name"]
input = tool_use["input"]
tool_id = tool_use["id"]

puts "Found tool use: #{name} with ID: #{tool_id}"

# 2) Invoke the MCP tool
puts "Calling MCP tool: #{name}"
puts "Tool input: #{input.inspect}"
# Input is already a Hash, no need to parse it
result = mcp_client.call_tool(name, input)
puts "Tool result received"

# 3) Add tool result to conversation
messages << {
  role: "assistant",
  content: response["content"]  # Include all content items from the assistant
}
messages << {
  role: "user",
  content: [
    {
      type: "tool_result",
      tool_use_id: tool_id,
      content: result.to_json
    }
  ]
}

# 4) Get final response from the model
puts "Getting final response..."
final = client.messages(
  parameters: {
    model: "claude-3-7-sonnet-20250219",
    messages: messages,
    system: "You can call filesystem tools.",
    tools: claude_tools,
    max_tokens: 1000
  }
)

# Print the final response content
if final["content"][0]["type"] == "text"
  puts final["content"][0]["text"]
else
  puts "Unexpected response format:"
  puts JSON.pretty_generate(final)
end