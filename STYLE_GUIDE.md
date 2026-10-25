# Style Guide

## Bash Scripts

### Header
Every script starts with:
```bash
#!/usr/bin/env bash
set -Eeuo pipefail
```

### Colors
Use the standard color palette:
```bash
if [[ -t 1 ]]; then
    CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    CYAN='' GREEN='' YELLOW='' RED='' NC=''
fi
```

Markers:
- `[*]` Cyan — Info
- `[+]` Green — Success
- `[!]` Yellow — Warning
- `[-]` Red — Error

### Logging Functions
```bash
log_info()  { printf "${CYAN}[*]${NC} %s\n" "$*"; }
log_ok()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
log_err()   { printf "${RED}[-]${NC} %s\n" "$*" >&2; }
die() { log_err "$*"; exit 1; }
```

### Structure
1. Header comment (purpose, usage, reads/outputs)
2. Color definitions
3. Logging functions
4. Argument parsing
5. Validation (fail fast with `die`)
6. Main logic
7. Summary output

### Conventions
- Use Mike Farah `yq` v4.44.3+ within v4; YAML consumers source `lib/tools.sh` and call `require_yq`
- Use `yq -r` for YAML reads and `yq -i` for in-place edits (not Python's `-iy`)
- Pass string values via environment variables and `strenv(...)`, not expression interpolation
- Use `yq -o=json` when handing YAML data to `jq`; jq-specific expressions belong in `jq`
- Use `awk` for floating-point comparisons
- Do not impose execution deadlines on downloads or inference; allow explicit cancellation
- Always check if required files exist before proceeding
- Always detect Ollama backend (Docker or native) before calling ollama
- Use `mapfile` for reading file lines into arrays
- Quote all variables
- Use `[[ ]]` for conditionals, not `[ ]`

### YAML (specs.yaml)
- Use 2-space indentation
- Keep sections in order: hardware, thresholds, models, rejected, candidates
- Use `null` for unset values (not empty strings)
- Use ISO dates (YYYY-MM-DD)

### Naming
- Scripts: `NN-description.sh` (zero-padded, lowercase, hyphenated)
- Files: lowercase with hyphens
- Variables: lowercase with underscores
- Functions: lowercase with underscores
