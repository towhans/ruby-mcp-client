#!/usr/bin/env python3
"""
FastMCP Echo Server Example

This is a simple MCP server using FastMCP that provides an echo tool.
It demonstrates basic MCP server functionality with SSE transport.

To run this server:
1. Install FastMCP: pip install fastmcp
2. Run the server: python echo_server.py
3. The server will start on http://localhost:8000

The server provides:
- An echo tool that returns the message you send to it
- SSE transport for real-time communication
- Compatible with the Ruby MCP client
"""

from fastmcp import FastMCP

# Create the MCP server instance
mcp = FastMCP("Echo Server")

@mcp.tool()
def echo(message: str) -> str:
    """Echo back the provided message"""
    return message

@mcp.tool()
def reverse(text: str) -> str:
    """Reverse the provided text"""
    return text[::-1]

@mcp.tool()
def uppercase(text: str) -> str:
    """Convert text to uppercase"""
    return text.upper()

@mcp.tool()
def count_words(text: str) -> dict:
    """Count words in the provided text"""
    words = text.split()
    return {
        "word_count": len(words),
        "character_count": len(text),
        "character_count_no_spaces": len(text.replace(" ", ""))
    }

if __name__ == "__main__":
    print("Starting FastMCP Echo Server...")
    print("Server will be available at: http://127.0.0.1:8000")
    print("SSE endpoint: http://127.0.0.1:8000/sse")
    print("JSON-RPC endpoint: http://127.0.0.1:8000/messages")
    print("\nAvailable tools:")
    print("- echo: Echo back a message")
    print("- reverse: Reverse text")
    print("- uppercase: Convert to uppercase")
    print("- count_words: Count words and characters")
    print("\nPress Ctrl+C to stop the server")
    
    mcp.run(transport="sse", host="127.0.0.1", port=8000)