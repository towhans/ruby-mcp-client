#!/usr/bin/env ruby
# frozen_string_literal: true

# Example script demonstrating Ruby MCP client with FastMCP echo server
#
# This script shows how to:
# 1. Connect to a FastMCP server via SSE
# 2. List available tools
# 3. Call tools with different parameters
# 4. Handle responses and errors
#
# Prerequisites:
# 1. Install FastMCP: pip install fastmcp
# 2. Start the echo server: python examples/echo_server.py
# 3. Run this client: bundle exec ruby examples/echo_server_client.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

# Create a logger for debugging (optional)
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '🚀 Ruby MCP Client - FastMCP Echo Server Example'
puts '=' * 50

# Server configuration
server_config = {
  type: 'sse',
  base_url: 'http://127.0.0.1:8000/sse',
  headers: {},
  read_timeout: 30,
  ping: 10,
  retries: 3,
  retry_backoff: 1,
  logger: logger
}

puts "📡 Connecting to FastMCP Echo Server at #{server_config[:base_url]}"

begin
  # Create MCP client
  client = MCPClient.create_client(
    mcp_server_configs: [server_config]
  )

  puts '✅ Connected successfully!'

  # List available tools
  puts "\n📋 Fetching available tools..."
  tools = client.list_tools

  puts "Found #{tools.length} tools:"
  tools.each_with_index do |tool, index|
    puts "  #{index + 1}. #{tool.name}: #{tool.description}"
    puts "     Parameters: #{tool.schema['properties'].keys.join(', ')}" if tool.schema && tool.schema['properties']
  end

  # Demonstrate each tool
  puts "\n🛠️  Demonstrating tool usage:"
  puts '-' * 30

  # 1. Echo tool
  puts "\n1. Testing echo tool:"
  message = 'Hello from Ruby MCP Client!'
  puts "   Input: #{message}"
  result = client.call_tool('echo', { message: message })
  output = result['content']&.first&.dig('text') || result['structuredContent']&.dig('result')
  puts "   Output: #{output}"

  # 2. Reverse tool
  puts "\n2. Testing reverse tool:"
  text = 'FastMCP with Ruby'
  puts "   Input: #{text}"
  result = client.call_tool('reverse', { text: text })
  output = result['content']&.first&.dig('text') || result['structuredContent']&.dig('result')
  puts "   Output: #{output}"

  # 3. Uppercase tool
  puts "\n3. Testing uppercase tool:"
  text = 'mcp protocol rocks!'
  puts "   Input: #{text}"
  result = client.call_tool('uppercase', { text: text })
  output = result['content']&.first&.dig('text') || result['structuredContent']&.dig('result')
  puts "   Output: #{output}"

  # 4. Count words tool
  puts "\n4. Testing count_words tool:"
  text = 'The Model Context Protocol enables seamless AI integration'
  puts "   Input: #{text}"
  result = client.call_tool('count_words', { text: text })
  output = result['structuredContent'] || result['content']&.first&.dig('text')
  puts "   Output: #{output}"

  # 5. Test streaming (if available)
  puts "\n5. Testing streaming capability:"
  client.call_tool_streaming('echo', { message: 'Streaming test' }) do |chunk|
    puts "   Streamed chunk: #{chunk}"
  end

  puts "\n✨ All tools tested successfully!"
rescue MCPClient::Errors::ConnectionError => e
  puts "❌ Connection Error: #{e.message}"
  puts "\n💡 Make sure the echo server is running:"
  puts '   python examples/echo_server.py'
rescue MCPClient::Errors::ToolCallError => e
  puts "❌ Tool Call Error: #{e.message}"
rescue StandardError => e
  puts "❌ Unexpected Error: #{e.class}: #{e.message}"
  puts e.backtrace.join("\n") if ENV['DEBUG']
ensure
  puts "\n🧹 Cleaning up..."
  client&.cleanup
  puts '👋 Done!'
end
