# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in ollama-model-match, please report it responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities
2. Email the maintainer directly or open a private security advisory on GitHub
3. Include steps to reproduce the vulnerability
4. Allow reasonable time for a fix before public disclosure

## Security Considerations

This project:
- Executes bash scripts that run `ollama` commands
- Downloads models from HuggingFace and Ollama registries
- Does not collect or transmit user data
- Does not store credentials or API keys
- Models are pulled from official sources only

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest (main) | ✅ |
| Older releases | ❌ |

## Dependencies

- `yq` (v3.x) — YAML parsing
- `jq` — JSON parsing
- `curl` — HTTP requests
- `ollama` — Model management
- `glow` (optional) — Markdown rendering

Keep these tools updated to their latest versions.