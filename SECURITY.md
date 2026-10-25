# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in ollama-model-match, please report it responsibly.

**Do not** open a public GitHub issue for security vulnerabilities. Instead:

1. Use [GitHub Security Advisories](https://github.com/robertsinfosec/ollama-model-match/security/advisories/new) to report privately
2. Or email the maintainer directly

## Vulnerability Disclosure Process

1. **Report** — Submit via GitHub Security Advisories or email
2. **Acknowledge** — Maintainer acknowledges within 48 hours
3. **Assess** — Vulnerability is triaged and severity assigned
4. **Fix** — Patch is developed and tested
5. **Disclose** — Coordinated disclosure after fix is released

## Security Considerations

This project:
- Executes bash scripts that run `ollama` commands
- Downloads models from HuggingFace and Ollama registries
- Does not collect or transmit user data
- Does not store credentials or API keys
- Models are pulled from official sources only

## Dependencies

- Mike Farah `yq` (v4.44.3+ within v4) — YAML parsing; Python yq is not supported
- `jq` — JSON parsing
- `curl` — HTTP requests
- `ollama` — Model management
- `glow` (optional) — Markdown rendering

Setup offers installation with explicit confirmation, or `--yes` for agents.
System package installs may require administrator privileges. The repo-local
`yq` installer pins v4.54.1 and checks upstream SHA256 hashes before execution;
update the pin and hashes together when upgrading. It does not replace system
executables or change the general command search PATH. Automatic package installs
use apt (Linux), Homebrew (macOS), or a responding Snap service for optional Glow;
other environments get manual guidance. Agent `--yes` never prompts for sudo credentials.

## References

- [OpenSSF Vulnerability Disclosure Guidelines](https://github.com/ossf/oss-vulnerability-guide)
- [GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories)
- [CVE Reporting](https://www.cve.org/ResourcesSupport/ReportRequest)
- [OWASP Vulnerability Disclosure Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Vulnerability_Disclosure_Cheat_Sheet.html)

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest (main) | Yes |
| Older releases | No |
