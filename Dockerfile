FROM node:20-slim

# Install system utilities commonly needed by agent tools
RUN apt-get update && apt-get install -y git curl ca-certificates procps && rm -rf /var/lib/apt/lists/*

# Install Claude Code and the official Chrome DevTools MCP server globally
RUN npm install -g @anthropic-ai/claude-code chrome-devtools-mcp

WORKDIR /workspace

ENTRYPOINT ["claude"]