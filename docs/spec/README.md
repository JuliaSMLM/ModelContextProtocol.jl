# MCP Specification Documents

This directory contains official Model Context Protocol (MCP) specifications and documentation for reference during development.

## Files

### mcp-llm-docs-index.txt
**Source**: https://modelcontextprotocol.io/llms.txt  
**Updated**: 2025-09-02  
**Purpose**: LLM-friendly index of MCP documentation with links to all major sections

A structured index designed for LLMs to quickly navigate MCP documentation. Contains:
- Links to all major documentation sections
- Specification versions and changelogs
- SDK documentation references
- Tutorial and example links

Use this when you need to reference specific MCP documentation sections.

### mcp-llm-docs-full.txt
**Source**: https://modelcontextprotocol.io/llms-full.txt  
**Updated**: 2025-09-02  
**Size**: ~768KB (11,833 lines)  
**Purpose**: Complete LLM-friendly MCP documentation

The full MCP documentation formatted for LLM consumption. This comprehensive document includes:
- Complete protocol specification
- Architecture and concepts
- Implementation guides
- SDK documentation
- Examples and tutorials
- Best practices

Use this when building MCP implementations or need detailed protocol information.

### mcp-transport-spec-v1.0.md
**Protocol Version**: 2025-03-26  
**Updated**: 2025-09-02  
**Purpose**: Streamable HTTP transport specification

Detailed specification for the MCP Streamable HTTP transport, including:
- Transport mechanisms (stdio and Streamable HTTP)
- Session management requirements
- SSE (Server-Sent Events) implementation
- Security requirements
- Protocol version negotiation

## Using These Documents

### For Development
When implementing MCP features, reference these documents to ensure compliance with the protocol specification. The LLM-friendly versions are specifically formatted to be easily parsed and understood by AI assistants.

### For AI Assistants
These documents are designed to be copied into conversations with LLMs like Claude when building MCP servers or clients. The formatting is optimized for AI comprehension and includes all necessary context.

### Keeping Documents Updated
These specifications should be periodically updated from their source URLs to ensure we're following the latest protocol versions:

```bash
# Update LLM-friendly index
curl -s https://modelcontextprotocol.io/llms.txt > mcp-llm-docs-index.txt

# Update full LLM documentation
curl -s https://modelcontextprotocol.io/llms-full.txt > mcp-llm-docs-full.txt
```

## Protocol Versions
- **Current Protocol**: 2025-06-18
- **Transport Spec**: 2025-03-26 (Streamable HTTP)
- **Previous**: 2024-11-05 (deprecated HTTP+SSE)

## Additional Resources
- Official Website: https://modelcontextprotocol.io
- GitHub: https://github.com/modelcontextprotocol
- Specification: https://spec.modelcontextprotocol.io