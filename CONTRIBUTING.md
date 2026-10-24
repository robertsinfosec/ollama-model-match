# Contributing to ollama-model-match

Thank you for your interest in contributing! This project aims to make local LLM evaluation accessible to everyone.

## How to Contribute

### Reporting Issues

- Use the [Bug Report](.github/ISSUE_TEMPLATE/bug_report.md) template for bugs
- Use the [Feature Request](.github/ISSUE_TEMPLATE/feature_request.md) template for new features
- Search existing issues before creating a new one

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test your changes (run `bash -n` on all scripts)
5. Commit with a clear message
6. Push and open a PR

### What to Contribute

- **New discovery sources** — Add more HuggingFace orgs or model registries
- **GPU support** — Improve Intel/AMD/Snapdragon detection
- **Eval prompts** — Better standardized test prompts
- **Bug fixes** — Especially around Ollama version differences
- **Documentation** — Improve README, SKILL.md, or inline comments

### Code Style

See [STYLE_GUIDE.md](STYLE_GUIDE.md) for bash scripting conventions.

### Testing Policy

All new functionality must be accompanied by tests. The test policy is:

1. **New scripts** must pass `bash -n` and ShellCheck with zero warnings
2. **New scripts** must be tested on at least one machine before submission
3. **Modified scripts** must not break existing functionality
4. **New scripts** must produce clear, color-coded output (`[*]`, `[+]`, `[!]`, `[-]`)
5. **All PRs** must pass the ShellCheck CI workflow

### Testing

Before submitting a PR:
- Run `bash -n` on all modified scripts
- Test on at least one machine (even if CPU-only)
- Verify the script produces clear, color-coded output

### Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Please be respectful and constructive.