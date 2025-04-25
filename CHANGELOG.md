# Changelog

## 0.5.0 (2025-04-25)

- Enhanced SSE implementation and added Faraday HTTP support
- Updates for the HTTP client and endpoints
- Updates session handling
- Remove parameters from ping
- Code improvements

## 0.4.1 (2025-04-24)

- Server ping functionality
- Fix SSE connection handling and add graceful fallbacks

## 0.4.0 (2025-04-23)

- Added full "initialize" hand-shake support to the SSE transport
  - Added an @initialized flag and ensure_initialized helper
  - Hooked into list_tools and call_tool for JSON-RPC "initialize" to be sent once
  - Implemented perform_initialize to send the RPC, capture server info and capabilities
  - Exposed server_info and capabilities readers on ServerSSE

- Added JSON-RPC notifications dispatcher
  - ServerBase#on_notification to register blocks for incoming JSON-RPC notifications
  - ServerStdio and ServerSSE now detect notification messages and invoke callbacks
  - Client#on_notification to register client-level listeners
  - Automatic tool cache invalidation on "notifications/tools/list_changed"

- Added generic JSON-RPC methods to both transports
  - ServerBase: abstract rpc_request/rpc_notify
  - ServerStdio: rpc_request for blocking request/response, rpc_notify for notifications
  - ServerSSE: rpc_request via HTTP POST, rpc_notify to SSE messages endpoint
  - Client: send_rpc and send_notification methods for client-side JSON-RPC dispatch

- Added timeout & retry configurability with improved logging
  - Per-call timeouts & retries for both transports
  - Tagged, leveled logging across all components
  - Consistent retry and logging functionality

## 0.3.0 (2025-04-23)

- Removed HTTP server implementation
- Code cleanup

## 0.2.0 (2025-04-23)

- Client schema validation
- Client streaming API fallback/delegation
- ServerHTTP initialization
- Added list_tools, call_tool with streaming fallback
- HTTP error handling
- Support for calling multiple functions in batch
- Implement find_tool
- Tool cache control
- Added ability to filter tools by name in to_openai_tools and to_anthropic_tools

## 0.1.0 (2025-04-23)

Initial release of ruby-mcp-client:

- Support for SSE (Server-Sent Events) transport
  - Robust connection handling with configurable timeouts
  - Thread-safe implementation
  - Error handling and resilience
  - JSON-RPC over SSE support
- Standard I/O transport support
- Converters for popular LLM APIs:
  - OpenAI tools format
  - Anthropic Claude tools format
- Examples for integration with:
  - Official OpenAI Ruby gem
  - Community OpenAI Ruby gem
  - Anthropic Ruby gem