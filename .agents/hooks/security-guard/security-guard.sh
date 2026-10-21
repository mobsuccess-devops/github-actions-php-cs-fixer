#!/bin/bash
#
# Security Guard Hook for Claude Code and Cursor
# Blocks dangerous and irreversible commands to enable safe usage with --dangerously-skip-permissions
#
# Supports:
#   - Claude Code: PreToolUse (tool_name: Bash, Edit, Write, Read, mcp__*)
#   - Cursor: preToolUse (tool_name: Shell, Edit, Write, Read, mcp__*), beforeShellExecution, beforeReadFile
#
# Exit codes:
#   0 - Allow the command
#   2 - Block the command (message sent to Claude via stderr)
#
# No external dependencies required (no jq) - uses only bash built-ins and standard Unix tools:
#   cat, head, tr, sed and grep (with POSIX ERE via -E, no GNU/PCRE extensions)
#

set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# ============================================================================
# JSON PARSING (pure bash/grep/sed/head - no jq required)
# ============================================================================

# Extract a simple string value from JSON: "key": "value"
# Handles escaped quotes \" inside values
# Returns empty string if key not found
# Usage: json_get "key" <<< "$json"
json_get() {
    local key="$1"
    local result
    # Match "key": "value" including escaped quotes, then extract and unescape
    result=$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" 2>/dev/null | head -1 || true)
    if [[ -n "$result" ]]; then
        # Extract value between quotes and unescape \"
        echo "$result" | sed "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\(.*\\)\"/\\1/" | sed 's/\\"/"/g'
    fi
}

# Extract tool_name and nested values from input
# Cursor uses "Shell" for shell commands; Claude Code uses "Bash"
# Cursor beforeShellExecution/beforeReadFile send command/file_path at top level (no tool_name)
TOOL_NAME=$(echo "$INPUT" | json_get "tool_name")
COMMAND=$(echo "$INPUT" | json_get "command")
FILE_PATH=$(echo "$INPUT" | json_get "file_path")
HOOK_EVENT=$(echo "$INPUT" | json_get "hook_event_name")
CURSOR_VERSION=$(echo "$INPUT" | json_get "cursor_version")

# Helper function to block with message
block() {
    echo "SECURITY GUARD: $1" >&2
    exit 2
}

# Cursor expects JSON output when allowing; Claude Code uses exit code only
allow() {
    [[ -n "$CURSOR_VERSION" ]] && echo '{"permission":"allow"}'
    exit 0
}

# ============================================================================
# BASH COMMAND VALIDATION
# ============================================================================
check_bash_command() {
    local cmd="$1"

    # Normalize command (lowercase for some checks)
    local cmd_lower=$(echo "$cmd" | tr '[:upper:]' '[:lower:]')

    # Strip quoted strings (single, double, heredoc bodies) to avoid false positives
    # on content inside commit messages, echo statements, etc.
    local cmd_no_quotes
    cmd_no_quotes=$(echo "$cmd" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")

    # --- SUDO OPERATIONS ---
    # Block all sudo commands - Claude Code should not require elevated privileges
    if echo "$cmd" | grep -qE '^[[:space:]]*sudo[[:space:]]+|;[[:space:]]*sudo[[:space:]]+|\|[[:space:]]*sudo[[:space:]]+|&&[[:space:]]*sudo[[:space:]]+|\([[:space:]]*sudo[[:space:]]+|\$\([[:space:]]*sudo[[:space:]]+'; then
        block "sudo commands are blocked. Claude Code should not require elevated privileges."
    fi

    # --- GIT DANGEROUS OPERATIONS ---

    # Force push (blocks all force push variants)
    if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+(.*[[:space:]])?(-f|--force|--force-with-lease)([[:space:]]|$)'; then
        block "git push --force is blocked. If you need to force push, please run the command manually in your terminal."
    fi

    # Hard reset
    if echo "$cmd" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard'; then
        block "git reset --hard is blocked. This discards all uncommitted changes irreversibly."
    fi

    # Clean with force
    if echo "$cmd" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[a-z]*f'; then
        block "git clean -f is blocked. This permanently deletes untracked files."
    fi

    # Rebase on shared branches
    if echo "$cmd" | grep -qE 'git[[:space:]]+rebase[[:space:]]+(--[^[:space:]]+[[:space:]]+)*(main|master|develop|release)([[:space:]]|$)'; then
        block "Rebasing onto shared branches is blocked. If you need to rebase, please run the command manually in your terminal."
    fi

    # --- DATABASE DESTRUCTIVE OPERATIONS ---

    # DROP operations
    if echo "$cmd_lower" | grep -qE '(drop[[:space:]]+(database|table|schema|index|view|trigger|procedure|function))'; then
        block "DROP DATABASE/TABLE/SCHEMA is blocked. This is irreversible data loss."
    fi

    # TRUNCATE
    if echo "$cmd_lower" | grep -qE 'truncate[[:space:]]+table'; then
        block "TRUNCATE TABLE is blocked. This deletes all data irreversibly."
    fi

    # DELETE without WHERE (check if DELETE FROM exists without WHERE in the same command)
    #
    # Known limitation: This pattern may produce false negatives if 'where' appears
    # in a SQL comment or string literal (e.g., "DELETE FROM x; -- where is this").
    # We accept this limitation because:
    # 1. Claude Code generates straightforward SQL, not obfuscated queries
    # 2. Proper SQL parsing in bash would be overly complex and fragile
    # 3. This is a heuristic safety net, not a SQL validator
    #
    if echo "$cmd_lower" | grep -qE 'delete[[:space:]]+from[[:space:]]+[a-z_]+' && ! echo "$cmd_lower" | grep -qiE 'where[[:space:]]+'; then
        block "DELETE FROM without WHERE clause is blocked. This deletes all rows."
    fi

    # Redis destructive operations
    if echo "$cmd_lower" | grep -qE 'redis-cli[[:space:]]+.*(flushall|flushdb|debug[[:space:]]+segfault)'; then
        block "Redis FLUSHALL/FLUSHDB is blocked. This deletes all data."
    fi

    # MongoDB destructive operations (patterns in lowercase since we use cmd_lower)
    if echo "$cmd_lower" | grep -qE '(mongo|mongosh).*(dropdatabase|dropcollection)'; then
        block "MongoDB dropDatabase/dropCollection is blocked. This deletes all data."
    fi

    # --- FILESYSTEM DESTRUCTIVE OPERATIONS ---

    # rm -rf on dangerous paths (but allow ./relative/paths)
    # Block: /home, /usr, /var, /etc, /opt, ..
    # `[[:space:]*]` is intentional and is valid POSIX: a bracket expression may
    # contain a character class next to literal characters, so it reads as
    # "whitespace or a literal *". Do not rewrite it as `([[:space:]]|\*)`.
    if echo "$cmd_no_quotes" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[fF]?[[:space:]]+(/home|/usr|/var|/etc|/opt|/boot|/bin|/sbin|/lib)(/([[:space:]*]|$)|[[:space:]]|$)'; then
        block "Recursive delete on system directories is blocked."
    fi

    # Block parent directory traversal (..)
    if echo "$cmd" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[fF]?[[:space:]]+\.\.'; then
        block "Recursive delete on parent directory (..) is blocked."
    fi

    # rm -rf /* or rm -rf / or rm -rf ~, ~/, ~/* (home root only)
    # Note: ~/ must NOT match sub-paths like ~/Documents/repo — those are personal
    # directories and are intentionally allowed (see FTTECH-11113). Only the home
    # root itself (~, ~/, ~/*) is catastrophic.
    if echo "$cmd_no_quotes" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[fF]?[[:space:]]+(/\*|/[[:space:]]*$|~/\*|~/[[:space:]]*$|~[[:space:]]*$)'; then
        block "Recursive delete on root or home is blocked. This is catastrophic."
    fi

    # Note: We intentionally don't block rm with variable expansion (e.g., rm -rf $DIR)
    # because it causes too many false positives for legitimate cleanup operations.
    # Users should be careful with unquoted variables in rm commands.

    # chmod 777
    if echo "$cmd" | grep -qE 'chmod[[:space:]]+(-R[[:space:]]+)?777'; then
        block "chmod 777 is blocked. This is a security vulnerability."
    fi

    # chown to root
    if echo "$cmd" | grep -qE 'chown[[:space:]]+(-R[[:space:]]+)?root'; then
        block "chown to root is blocked for safety."
    fi

    # Disk operations
    if echo "$cmd" | grep -qE '(mkfs|fdisk|parted|dd[[:space:]]+if=)'; then
        block "Disk formatting/partitioning operations are blocked."
    fi

    # Fork bomb
    if echo "$cmd" | grep -qE ':\(\)[[:space:]]*\{.*:[[:space:]]*&[[:space:]]*\}[[:space:]]*;?[[:space:]]*:'; then
        block "Fork bomb detected and blocked."
    fi

    # Direct write to devices
    if echo "$cmd" | grep -qE '>[[:space:]]*/dev/(sd|hd|nvme|vd)'; then
        block "Direct write to disk devices is blocked."
    fi

    # --- DOCKER DANGEROUS OPERATIONS ---

    # Block ALL container removal (docker rm, docker remove, docker container rm)
    if echo "$cmd" | grep -qE 'docker[[:space:]]+(rm|remove|container[[:space:]]+rm|container[[:space:]]+remove)[[:space:]]'; then
        block "Removing Docker containers is blocked."
    fi

    # Block docker stop (can disrupt services)
    if echo "$cmd" | grep -qE 'docker[[:space:]]+(stop|kill|container[[:space:]]+stop|container[[:space:]]+kill)[[:space:]]'; then
        block "Stopping/killing Docker containers is blocked."
    fi

    # System prune (any variant)
    if echo "$cmd" | grep -qE 'docker[[:space:]]+system[[:space:]]+prune'; then
        block "docker system prune is blocked. This removes unused data."
    fi

    # Volume prune or remove
    if echo "$cmd" | grep -qE 'docker[[:space:]]+volume[[:space:]]+(prune|rm|remove)'; then
        block "Docker volume deletion is blocked."
    fi

    # Image removal
    if echo "$cmd" | grep -qE 'docker[[:space:]]+(rmi|image[[:space:]]+rm|image[[:space:]]+remove)[[:space:]]'; then
        block "Docker image removal is blocked."
    fi

    # Network removal
    if echo "$cmd" | grep -qE 'docker[[:space:]]+network[[:space:]]+(rm|remove)[[:space:]]'; then
        block "Docker network removal is blocked."
    fi

    # --- KUBERNETES DANGEROUS OPERATIONS ---

    # Delete namespace
    if echo "$cmd" | grep -qE 'kubectl[[:space:]]+delete[[:space:]]+(namespace|ns)[[:space:]]'; then
        block "kubectl delete namespace is blocked. This deletes all resources in the namespace."
    fi

    # Delete all resources
    if echo "$cmd" | grep -qE 'kubectl[[:space:]]+.*delete[[:space:]]+.*--all|kubectl[[:space:]]+delete[[:space:]]+[a-z]+[[:space:]]+--all'; then
        block "kubectl delete --all is blocked."
    fi

    # Delete in production (check for -n prod or --namespace=prod anywhere in command)
    if echo "$cmd" | grep -qE 'kubectl.*(-n[= ](prod|production)|--namespace[= ](prod|production)).*delete|kubectl.*delete.*(-n[= ](prod|production)|--namespace[= ](prod|production))'; then
        block "kubectl delete in production namespace is blocked."
    fi

    # --- CLOUD PROVIDER DANGEROUS OPERATIONS ---

    # AWS S3 recursive delete
    if echo "$cmd" | grep -qE 'aws[[:space:]]+s3[[:space:]]+(rm|rb)[[:space:]]+.*--recursive'; then
        block "aws s3 rm --recursive is blocked. This deletes all objects."
    fi

    # AWS EC2 destructive operations
    if echo "$cmd" | grep -qE 'aws[[:space:]]+ec2[[:space:]]+(terminate-instances|delete-|modify-instance-attribute)'; then
        block "aws ec2 destructive operation is blocked."
    fi

    # AWS RDS destructive operations
    if echo "$cmd" | grep -qE 'aws[[:space:]]+rds[[:space:]]+(delete-db-instance|delete-db-cluster|delete-db-snapshot)'; then
        block "aws rds delete operation is blocked. This can cause data loss."
    fi

    # AWS Lambda destructive operations
    if echo "$cmd" | grep -qE 'aws[[:space:]]+lambda[[:space:]]+(delete-function|delete-layer-version)'; then
        block "aws lambda delete operation is blocked."
    fi

    # AWS IAM destructive operations
    if echo "$cmd" | grep -qE 'aws[[:space:]]+iam[[:space:]]+(delete-user|delete-role|delete-policy|remove-user-from-group)'; then
        block "aws iam destructive operation is blocked."
    fi

    # AWS CloudFormation destructive operations
    if echo "$cmd" | grep -qE 'aws[[:space:]]+cloudformation[[:space:]]+(delete-stack|delete-stack-set)'; then
        block "aws cloudformation delete operation is blocked."
    fi

    # AWS general delete pattern (catch-all for other services)
    if echo "$cmd" | grep -qE 'aws[[:space:]]+[a-z0-9-]+[[:space:]]+delete-'; then
        block "aws delete operation is blocked. Review and run manually if needed."
    fi

    # Terraform destroy
    if echo "$cmd" | grep -qE 'terraform[[:space:]]+destroy'; then
        block "terraform destroy is blocked. Run this manually with proper review."
    fi

    # --- PACKAGE MANAGER DANGEROUS OPERATIONS ---

    # Global package installations (npm, pnpm, yarn)
    # These modify system-wide packages and can install malicious code globally
    if echo "$cmd" | grep -qE 'npm[[:space:]]+(install|i)[[:space:]]+.*-g|npm[[:space:]]+(install|i)[[:space:]]+-g'; then
        block "npm global install (-g) is blocked. Install packages locally instead."
    fi

    if echo "$cmd" | grep -qE 'pnpm[[:space:]]+(add|install|i)[[:space:]]+.*-g|pnpm[[:space:]]+(add|install|i)[[:space:]]+-g'; then
        block "pnpm global install (-g) is blocked. Install packages locally instead."
    fi

    if echo "$cmd" | grep -qE 'yarn[[:space:]]+global[[:space:]]+add'; then
        block "yarn global add is blocked. Install packages locally instead."
    fi

    # npm unpublish
    if echo "$cmd" | grep -qE 'npm[[:space:]]+unpublish'; then
        block "npm unpublish is blocked. This can break dependent packages."
    fi

    # --- PROCESS/SYSTEM OPERATIONS ---

    # Kill all processes or dangerous killall usage
    if echo "$cmd" | grep -qE 'kill[[:space:]]+-9[[:space:]]+(-1|0)|killall[[:space:]]+(-9[[:space:]]+)?(-1|init|systemd|kernel)'; then
        block "Killing system processes is blocked."
    fi

    # Shutdown/reboot
    if echo "$cmd" | grep -qE '(shutdown|reboot|init[[:space:]]+[06])'; then
        block "System shutdown/reboot is blocked."
    fi

    # --- CURL/WGET PIPE TO SHELL ---

    if echo "$cmd" | grep -qE '(curl|wget)[[:space:]]+.*\|[[:space:]]*(ba)?sh'; then
        block "Piping downloaded content to shell is blocked. Download and review first."
    fi

    # --- HISTORY/CREDENTIAL MANIPULATION ---

    # Clear history
    if echo "$cmd" | grep -qE '(history[[:space:]]+-c|>[[:space:]]*~/\..*history)'; then
        block "Clearing shell history is blocked."
    fi

    # --- SENSITIVE FILE READING ---

    # Block reading sensitive files via common commands
    # Matches: cat, head, tail, less, more, bat, view, vim, nano, etc.
    local read_cmds='(cat|head|tail|less|more|bat|view|vim|vi|nano|grep|awk|sed|strings|xxd|hexdump|od|file|stat|wc)'

    # --- SYSTEM AUTHENTICATION FILES ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*/etc/(passwd|shadow|sudoers|gshadow|master\.passwd|login\.defs)"; then
        block "Reading system authentication files is blocked."
    fi

    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*/etc/(security|pam\.d)/"; then
        block "Reading PAM/security configuration is blocked."
    fi

    # --- SSH FILES ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*/etc/ssh/"; then
        block "Reading SSH server configuration is blocked."
    fi

    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*\.ssh/(id_[a-z_]+|identity|config|known_hosts|authorized_keys)"; then
        block "Reading SSH files is blocked."
    fi

    # --- SSL/TLS PRIVATE KEYS ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*/etc/(ssl/private|pki)/"; then
        block "Reading SSL/TLS private keys is blocked."
    fi

    # --- CLOUD CREDENTIALS ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*\.(aws|azure|gcloud|config/gcloud)/"; then
        block "Reading cloud provider credentials is blocked."
    fi

    # --- ENVIRONMENT FILES ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*\.env(\.[a-z]+)?([[:space:]]|$|;|\|)"; then
        block "Reading .env files is blocked. These may contain secrets."
    fi

    # --- GIT CREDENTIALS ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(\.git-credentials|\.netrc|\.gitconfig)([[:space:]]|$|;|\|)"; then
        block "Reading git credentials/config is blocked."
    fi

    # --- PACKAGE MANAGER CONFIGS ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(\.npmrc|\.yarnrc|\.pypirc|\.gem/credentials)"; then
        block "Reading package manager config is blocked."
    fi

    # --- KUBERNETES/DOCKER ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(\.kube/config|\.docker/config\.json)"; then
        block "Reading container orchestration config is blocked."
    fi

    # --- BROWSER DATA ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(Chrome|Firefox|Safari|Brave|Edge).*(Cookies|Login|History|Passwords)"; then
        block "Reading browser data is blocked."
    fi

    # --- KEYCHAIN/KEYRING ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(\.gnupg|\.password-store|keyrings|Keychains)/"; then
        block "Reading keychain/keyring data is blocked."
    fi

    # --- SYSTEM LOGS ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*/var/log/(auth|secure|audit)"; then
        block "Reading system authentication logs is blocked."
    fi

    # --- SECRETS DIRECTORIES ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(^|/)(secrets?|credentials?|private)/"; then
        block "Reading from secrets/credentials directories is blocked."
    fi

    # --- SHELL HISTORY ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*(\.bash_history|\.zsh_history|\.sh_history)"; then
        block "Reading shell history is blocked."
    fi

    # --- PRIVATE KEYS ---
    if echo "$cmd_no_quotes" | grep -qE "$read_cmds[[:space:]]+.*\.(pem|key|p12|pfx|jks)([[:space:]]|$|;|\|)"; then
        block "Reading private key files is blocked."
    fi
}

# ============================================================================
# FILE PATH VALIDATION (for Edit, Write, Read tools)
# ============================================================================
check_file_path() {
    local file_path="$1"
    local tool="$2"

    # Block reading sensitive files
    if [[ "$tool" == "Read" ]]; then

        # --- SYSTEM AUTHENTICATION FILES ---
        if echo "$file_path" | grep -qE '^/etc/(passwd|shadow|sudoers|sudoers\.d/|gshadow|master\.passwd|login\.defs|security/)'; then
            block "Reading system authentication files is blocked."
        fi

        # PAM configuration
        if echo "$file_path" | grep -qE '^/etc/pam\.d/'; then
            block "Reading PAM configuration is blocked."
        fi

        # --- SSH FILES ---
        # Server and user SSH keys and configs
        if echo "$file_path" | grep -qE '^/etc/ssh/'; then
            block "Reading SSH server configuration is blocked."
        fi

        if echo "$file_path" | grep -qE '\.ssh/(id_[^.]+|identity|config|known_hosts|authorized_keys)'; then
            block "Reading SSH files is blocked."
        fi

        # --- SSL/TLS PRIVATE KEYS ---
        if echo "$file_path" | grep -qE '^/etc/ssl/private/|^/etc/pki/'; then
            block "Reading SSL/TLS private keys is blocked."
        fi

        # --- CLOUD CREDENTIALS ---
        if echo "$file_path" | grep -qE '\.(aws|azure|gcloud|config/gcloud)/'; then
            block "Reading cloud provider credentials is blocked."
        fi

        # --- ENVIRONMENT FILES ---
        if echo "$file_path" | grep -qE '\.env(\.[a-z]+)?$'; then
            block "Reading .env files is blocked. These may contain secrets."
        fi

        # --- GIT CREDENTIALS ---
        if echo "$file_path" | grep -qE '(\.git-credentials|\.netrc|\.gitconfig)$'; then
            block "Reading git credentials/config is blocked."
        fi

        # --- PACKAGE MANAGER CONFIGS (may contain tokens) ---
        if echo "$file_path" | grep -qE '\.(npmrc|yarnrc|pip/pip\.conf|pypirc|gem/credentials|composer/auth\.json)'; then
            block "Reading package manager config is blocked. May contain auth tokens."
        fi

        # --- KUBERNETES/DOCKER ---
        if echo "$file_path" | grep -qE '\.(kube/config|docker/config\.json)'; then
            block "Reading container orchestration config is blocked."
        fi

        # --- BROWSER DATA ---
        if echo "$file_path" | grep -qE '(Chrome|Firefox|Safari|Brave|Edge|Opera).*(Cookies|Login Data|History|Passwords|Web Data)'; then
            block "Reading browser data is blocked."
        fi

        # --- KEYCHAIN/KEYRING ---
        if echo "$file_path" | grep -qE '(\.gnupg/|\.password-store/|\.local/share/keyrings/|Library/Keychains/)'; then
            block "Reading keychain/keyring data is blocked."
        fi

        # --- SYSTEM LOGS (may contain sensitive info) ---
        if echo "$file_path" | grep -qE '^/var/log/(auth|secure|audit|syslog|messages)'; then
            block "Reading system authentication logs is blocked."
        fi

        # --- DATABASE FILES ---
        if echo "$file_path" | grep -qE '\.(sqlite|sqlite3|db)$' && echo "$file_path" | grep -qiE '(password|credential|secret|token|key|auth)'; then
            block "Reading potentially sensitive database files is blocked."
        fi

        # --- SECRETS DIRECTORIES ---
        if echo "$file_path" | grep -qE '(^|/)(secrets?|credentials?|private|\.secrets?|\.credentials?)/'; then
            block "Reading from secrets/credentials directories is blocked."
        fi

        # --- APPLICATION TOKENS/CONFIGS ---
        if echo "$file_path" | grep -qE '(\.slack|\.discord|\.telegram|\.config/gh/hosts\.yml)'; then
            block "Reading application tokens/configs is blocked."
        fi

        # --- SHELL HISTORY (contains command history) ---
        if echo "$file_path" | grep -qE '\.(bash_history|zsh_history|sh_history|history|psql_history|mysql_history|node_repl_history)'; then
            block "Reading shell/command history is blocked."
        fi

        # --- PRIVATE KEYS (generic) ---
        if echo "$file_path" | grep -qE '\.(pem|key|p12|pfx|jks)$'; then
            block "Reading private key files is blocked."
        fi
    fi

    # Block writes to sensitive files
    if [[ "$tool" == "Write" || "$tool" == "Edit" ]]; then

        # Environment files with secrets
        if echo "$file_path" | grep -qE '\.env(\.[a-z]+)?$'; then
            block "Writing to .env files is blocked. These may contain secrets."
        fi

        # AWS credentials
        if echo "$file_path" | grep -qE '\.aws/(credentials|config)$'; then
            block "Writing to AWS credentials is blocked."
        fi

        # SSH keys
        if echo "$file_path" | grep -qE '\.ssh/(id_|authorized_keys|known_hosts)'; then
            block "Writing to SSH key files is blocked."
        fi

        # Kubernetes config
        if echo "$file_path" | grep -qE '\.kube/config$'; then
            block "Writing to kubeconfig is blocked."
        fi

        # Git credentials
        if echo "$file_path" | grep -qE '\.git-credentials$|\.netrc$'; then
            block "Writing to git credentials is blocked."
        fi

        # npmrc with tokens
        if echo "$file_path" | grep -qE '\.npmrc$'; then
            block "Writing to .npmrc is blocked. May contain auth tokens."
        fi

        # Package lock files (can cause dependency issues)
        if echo "$file_path" | grep -qE '(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$'; then
            block "Direct editing of lock files is blocked. Use package manager commands."
        fi

        # Docker secrets
        if echo "$file_path" | grep -qE '\.docker/config\.json$'; then
            block "Writing to Docker config is blocked. May contain registry credentials."
        fi

        # System files
        if echo "$file_path" | grep -qE '^/(etc|usr|var|boot|sys|proc)/'; then
            block "Writing to system directories is blocked."
        fi

        # Secrets directories (match as complete directory components)
        if echo "$file_path" | grep -qE '(^|/)(secrets?|credentials?|private)/'; then
            block "Writing to secrets/credentials directories is blocked. Review manually."
        fi
    fi
}

# ============================================================================
# MCP TOOL VALIDATION
# ============================================================================
check_mcp_tool() {
    local tool_name="$1"

    # Block potentially dangerous MCP operations
    # Add specific MCP server checks here based on your setup

    # Example: block destructive database MCP operations
    if echo "$tool_name" | grep -qE 'mcp__.*__(delete|drop|truncate|destroy)'; then
        block "Destructive MCP operation detected: $tool_name"
    fi
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

# Cursor beforeShellExecution sends { "command": "..." } (no tool_name)
# Cursor beforeReadFile sends { "file_path": "..." } (no tool_name)
if [[ -z "$TOOL_NAME" && -n "$COMMAND" ]]; then
    check_bash_command "$COMMAND"
    allow
fi
if [[ -z "$TOOL_NAME" && -n "$FILE_PATH" ]]; then
    check_file_path "$FILE_PATH" "Read"
    allow
fi

case "$TOOL_NAME" in
    Bash|Shell)
        if [[ -n "$COMMAND" ]]; then
            check_bash_command "$COMMAND"
        fi
        ;;

    Edit|Write|Read)
        if [[ -n "$FILE_PATH" ]]; then
            check_file_path "$FILE_PATH" "$TOOL_NAME"
        fi
        ;;

    mcp__*)
        check_mcp_tool "$TOOL_NAME"
        ;;

    *)
        # Allow other tools by default
        ;;
esac

# If we reach here, the command is allowed
allow
