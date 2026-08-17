#!/bin/bash
#
# Claude Code File Read Limit Fix Script
#
# Increases the file read token limit from 25000 to 1000000.
#
# THE ISSUE:
# Claude Code has a hardcoded token limit of 25000 for file reads,
# which can truncate large files when reading them.
#
# THE FIX:
# This script patches the limit to 1000000 tokens, allowing much larger
# files to be read in full.
#
# FIX POINT:
# =25000, (near <system-reminder>) → =1000000,
#
# Usage:
#   ./apply-claude-code-file-read-limit-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-file-read-limit-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-file-read-limit-fix.sh --check            # Check only
#   ./apply-claude-code-file-read-limit-fix.sh --restore          # Restore backup
#

set -e

BACKUP_SUFFIX="backup-filereadlimit"
NEW_LIMIT="100000"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[X]${NC} $1"; }
info() { echo -e "${BLUE}[>]${NC} $1"; }

CHECK_ONLY=false
RESTORE=false
CLI_PATH_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --check|-c) CHECK_ONLY=true; shift ;;
        --restore|-r) RESTORE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [options] [cli.js path]"
            echo ""
            echo "Increase file read token limit from 25000 to $NEW_LIMIT"
            echo ""
            echo "Arguments:"
            echo "  cli.js path    Path to cli.js file (optional, auto-detect if not provided)"
            echo ""
            echo "Options:"
            echo "  --check, -c    Check if fix is needed without making changes"
            echo "  --restore, -r  Restore original file from backup"
            echo "  --help, -h     Show help information"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "$CLI_PATH_ARG" ]]; then
                CLI_PATH_ARG="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

find_cli_path() {
    local locations=(
        "$HOME/.claude/local/node_modules/@cometix/claude-code/cli.js"
        "/usr/local/lib/node_modules/@cometix/claude-code/cli.js"
        "/usr/lib/node_modules/@cometix/claude-code/cli.js"
    )
    if command -v npm &> /dev/null; then
        local npm_root
        npm_root=$(npm root -g 2>/dev/null || true)
        if [[ -n "$npm_root" ]]; then
            locations+=("$npm_root/@cometix/claude-code/cli.js")
        fi
    fi
    for path in "${locations[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

if [[ -n "$CLI_PATH_ARG" ]]; then
    if [[ -f "$CLI_PATH_ARG" ]]; then
        CLI_PATH="$CLI_PATH_ARG"
        info "Using specified cli.js: $CLI_PATH"
    else
        error "Specified file not found: $CLI_PATH_ARG"
        exit 1
    fi
else
    CLI_PATH=$(find_cli_path) || {
        error "Claude Code cli.js not found"
        echo ""
        echo "Searched locations:"
        echo "  ~/.claude/local/node_modules/@cometix/claude-code/cli.js"
        echo "  /usr/local/lib/node_modules/@cometix/claude-code/cli.js"
        echo "  \$(npm root -g)/@cometix/claude-code/cli.js"
        echo ""
        echo "Tip: You can specify the path directly:"
        echo "  $0 /path/to/cli.js"
        exit 1
    }
    info "Found Claude Code: $CLI_PATH"
fi

CLI_DIR=$(dirname "$CLI_PATH")

if $RESTORE; then
    LATEST_BACKUP=$(ls -t "$CLI_DIR"/cli.js.${BACKUP_SUFFIX}-* 2>/dev/null | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        cp "$LATEST_BACKUP" "$CLI_PATH"
        success "Restored from backup: $LATEST_BACKUP"
        exit 0
    else
        error "No backup file found (cli.js.${BACKUP_SUFFIX}-*)"
        exit 1
    fi
fi

echo ""

# Create patch script
PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');

const cliPath = process.argv[2];
const checkOnly = process.argv[3] === '--check';
const newLimit = process.argv[4] || '1000000';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup-filereadlimit';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

// ============================================================
// Pattern: =25000, followed by <system-reminder> within ~100 chars
// This ensures we target the correct 25000 value (file read limit)
// ============================================================

const pattern = /=25000,([\s\S]{0,100})<system-reminder>/;
const match = code.match(pattern);

if (!match || match.index === undefined) {
    // Check if already patched
    const patchedPattern = new RegExp(`=${newLimit},[\\s\\S]{0,100}<system-reminder>`);
    if (patchedPattern.test(code)) {
        console.log('ALREADY_PATCHED');
        process.exit(2);
    }

    console.error('NOT_FOUND:Failed to find 25000 token limit near system-reminder');
    process.exit(1);
}

console.log('FOUND:=25000, near <system-reminder>');

if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:1');
    process.exit(1);
}

// Apply fix
// The "25000" starts at match.index + 1 (after the "=")
const startIndex = match.index + 1;
const endIndex = startIndex + 5;  // "25000" is 5 characters

const newCode = code.slice(0, startIndex) + newLimit + code.slice(endIndex);

console.log('PATCH:File read limit 25000 -> ' + newLimit);

// Backup original file
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

// Write patched file
fs.writeFileSync(cliPath, shebang + newCode);

console.log('SUCCESS:1');
PATCH_EOF

CHECK_ARG=""
if $CHECK_ONLY; then
    CHECK_ARG="--check"
fi

export BACKUP_SUFFIX
OUTPUT=$(node "$PATCH_SCRIPT" "$CLI_PATH" "$CHECK_ARG" "$NEW_LIMIT" 2>&1) || true
EXIT_CODE=$?

rm -f "$PATCH_SCRIPT"

while IFS= read -r line; do
    case "$line" in
        ALREADY_PATCHED)
            success "Already patched (limit is $NEW_LIMIT)"
            exit 0
            ;;
        NOT_FOUND:*)
            error "Target code not found: ${line#NOT_FOUND:}"
            exit 1
            ;;
        FOUND:*)
            info "Found: ${line#FOUND:}"
            ;;
        PATCH:*)
            info "Patch: ${line#PATCH:}"
            ;;
        NEEDS_PATCH)
            echo ""
            warning "Patch needed - run without --check to apply"
            ;;
        PATCH_COUNT:*)
            info "Need to patch ${line#PATCH_COUNT:} location(s)"
            exit 1
            ;;
        BACKUP:*)
            echo ""
            echo "Backup: ${line#BACKUP:}"
            ;;
        SUCCESS:*)
            echo ""
            success "Fix applied successfully! Patched ${line#SUCCESS:} location(s)"
            echo ""
            warning "Restart Claude Code for changes to take effect"
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
