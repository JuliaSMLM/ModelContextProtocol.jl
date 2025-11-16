# Changelog

All notable changes to ModelContextProtocol.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2025-11-16

### Breaking Changes

#### Server Version Default
- **BREAKING**: `mcp_server(...)` `version` parameter default changed from `"2024-11-05"` to `"1.0.0"`
  - **Rationale**: The version field represents YOUR server's implementation version, not the MCP protocol version
  - **Migration**: If you relied on the default, explicitly specify `version = "2024-11-05"` or update to semantic versioning
  - **Example**:
    ```julia
    # Old (implicit default)
    server = mcp_server(name = "my-server")  # version was "2024-11-05"

    # New (explicit version recommended)
    server = mcp_server(name = "my-server", version = "1.0.0")
    ```

#### Protocol Version Enforcement
- **BREAKING**: MCP protocol version `2025-06-18` is now strictly enforced
  - Only accepts `MCP-Protocol-Version: 2025-06-18` header
  - Returns error `-32600` (INVALID_REQUEST) for unsupported versions
  - **Migration**: Ensure clients send correct protocol version header

#### JSON-RPC Batching Removed
- **BREAKING**: JSON-RPC batch requests now return error per MCP 2025-06-18 specification
  - Batch arrays are explicitly rejected with error code `-32600`
  - **Migration**: Send requests one at a time instead of batching
  - **Example**:
    ```julia
    # Old (no longer supported)
    [{"jsonrpc":"2.0","method":"tools/list","id":1},
     {"jsonrpc":"2.0","method":"resources/list","id":2}]

    # New (send separately)
    {"jsonrpc":"2.0","method":"tools/list","id":1}
    # then
    {"jsonrpc":"2.0","method":"resources/list","id":2}
    ```

#### Auto-Registration File Format
- **BREAKING**: Auto-registered component files must have the component as the **last expression**
  - Old behavior: Searched all module variables for matching types
  - New behavior: Uses `include()` return value (last expression)
  - **Migration**: Ensure your component definition is the last line in the file
  - **Example**:
    ```julia
    # Old (may have worked)
    using ModelContextProtocol
    const my_tool = MCPTool(...)
    println("Tool loaded")  # Last expression

    # New (required format)
    using ModelContextProtocol  # Auto-imported by auto_register!
    println("Loading tool...")

    MCPTool(...)  # Must be last expression
    ```

### Added

#### HTTP Transport with SSE
- Full Streamable HTTP transport implementation following MCP specification
- Server-Sent Events (SSE) for real-time streaming via GET requests
- Session management with `Mcp-Session-Id` headers
- Origin validation and security features
- Connection lifecycle management
- Example: `examples/simple_http_server.jl`

#### Auto-Registration System
- Directory-based component organization (`tools/`, `resources/`, `prompts/`)
- Automatic discovery and loading of components
- Proper error handling and logging
- Support for both stdio and HTTP transports
- Example: `examples/reg_dir.jl`, `examples/reg_dir_http.jl`

#### New Content Types
- `ResourceLink`: Reference resources in tool results (MCP 2025-06-18 feature)
- Enhanced content serialization with `content2dict()`

#### Documentation
- Comprehensive transport documentation (`docs/src/transports.md`)
- Auto-registration guide (`docs/src/auto-registration.md`)
- Claude Desktop integration guide (`docs/src/claude.md`)
- Improved API documentation with multi-transport examples
- Fixed broken examples in documentation

### Changed

#### Transport Abstraction
- Introduced `Transport` abstract type with `StdioTransport` and `HttpTransport` implementations
- `start!(server)` now accepts optional `transport` parameter (defaults to `StdioTransport()`)
- **Note**: This is NOT a breaking change - `start!(server)` still works as before
- Server loop now uses transport abstraction (`read_message`, `write_message`)

#### Improved Error Handling
- Better error messages for protocol violations
- Proper error responses for unsupported features
- Enhanced logging with structured metadata

#### Test Suite
- Added comprehensive HTTP transport tests
- Added protocol compliance tests
- All 233 tests passing

### Fixed

- Auto-registration for Julia 1.12+ world age changes (backward compatible)
- SSE streaming test failures
- Inspector CLI compatibility issues
- Examples now work correctly in stdio mode
- Documentation examples now execute successfully

### Internal

- Refactored type system consolidation
- Improved server lifecycle management
- Enhanced MCP-compliant logging
- Better separation of protocol vs server version

## [0.2.1] - 2025-08-01

### Changed
- Reorganized test suite following Julia conventions
- Integrated API documentation into help system
- Bump version for API documentation improvements

## [0.2.0] - 2025-07-28

### Changed
- Changed default `MCPTool` `return_type` to `Vector{Content}` (breaking change for tools expecting single content validation)
- Updated tool handler system to support multi-content returns

## [0.1.0] - 2025-06-18

### Added
- Initial release
- Core MCP server implementation
- Tools, Resources, and Prompts support
- stdio transport
- Basic protocol compliance

[Unreleased]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/releases/tag/v0.1.0
