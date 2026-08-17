#!/bin/bash
#
# Claude Code Keybindings Customization Fix Script
#
# THE FEATURE:
# Custom keybindings allow users to remap keyboard shortcuts via
# ~/.claude/keybindings.json. Since v2.1.x, Ctrl+C is mapped to
# app:interrupt which directly aborts the agent loop — a behavior
# change from v2.0.x where only Escape could interrupt.
#
# THE PROBLEMS:
# 1. Keybinding customization is gated behind the feature flag
#    "tengu_keybinding_customization_release" (defaults to false).
# 2. The default binding "ctrl+c": "app:interrupt" causes accidental
#    agent loop interruptions (v2.0.x used Escape only).
#
# FIX (2 patches):
# 1. Force-enable keybinding customization feature flag.
# 2. Change default ctrl+c binding from "app:interrupt" to "app:exit"
#    so Ctrl+C exits (like v2.0.x) and only Escape interrupts.
#
# Usage:
#   ./apply-claude-code-enable-keybindings-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-enable-keybindings-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-enable-keybindings-fix.sh --check            # Check only
#   ./apply-claude-code-enable-keybindings-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-keybindings-enable"
FIX_DESCRIPTION="Force-enable keybinding customization by overriding feature flag"

# ============================================================
# Color output functions
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[X]${NC} $1"; }
info() { echo -e "${BLUE}[>]${NC} $1"; }

# ============================================================
# Argument parsing
# ============================================================
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
            echo "$FIX_DESCRIPTION"
            echo ""
            echo "Arguments:"
            echo "  cli.js path    Path to cli.js file (optional, auto-detect if not provided)"
            echo ""
            echo "Options:"
            echo "  --check, -c    Check if fix is needed without making changes"
            echo "  --restore, -r  Restore original file from backup"
            echo "  --help, -h     Show help information"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Auto-detect and apply fix"
            echo "  $0 /path/to/cli.js                    # Apply fix to specific file"
            echo "  $0 --check /path/to/cli.js            # Check specific file"
            echo "  $0 /path/to/cli.js --check            # Same as above"
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

# ============================================================
# Find Claude Code cli.js path
# ============================================================
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

# ============================================================
# Determine CLI_PATH: use provided path or auto-detect
# ============================================================
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

# ============================================================
# Restore backup
# ============================================================
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

# ============================================================
# Download acorn parser if needed
# ============================================================
ACORN_PATH="/tmp/acorn-claude-fix.js"
if [[ ! -f "$ACORN_PATH" ]]; then
    info "Downloading acorn parser..."
    curl -sL "https://unpkg.com/acorn@8.16.0/dist/acorn.js" -o "$ACORN_PATH" || {
        error "Failed to download acorn parser"
        exit 1
    }
fi

# ============================================================
# Node.js patch script (heredoc)
# ============================================================
PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');
const acornPath = process.argv[2];
const acorn = require(acornPath);

const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

// ============================================================
// Fix: Force-enable keybinding customization by patching tengu_keybinding_customization_release flag
// ============================================================

let fixes = {
    featureFlag: { found: false, patched: false, node: null },
    ctrlCBinding: { found: false, patched: false, node: null },
};

// Parse AST
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// AST walker
function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

// ============================================================
// Patch 1: Force-enable tengu_keybinding_customization_release
//
// Target: fn("tengu_keybinding_customization_release", !1)
// ============================================================

const callExprs = findNodes(ast, n =>
    n.type === 'CallExpression' &&
    n.arguments &&
    n.arguments.length === 2 &&
    n.arguments[0].type === 'Literal' &&
    n.arguments[0].value === 'tengu_keybinding_customization_release'
);

let calleeName = '';
let flagAlreadyPatched = false;

for (const call of callExprs) {
    calleeName = src(call.callee);
    const secondArg = call.arguments[1];

    if (secondArg.type === 'UnaryExpression' &&
        secondArg.operator === '!' &&
        secondArg.argument.type === 'Literal' &&
        secondArg.argument.value === 1) {
        fixes.featureFlag.found = true;
        fixes.featureFlag.node = secondArg;
        console.log('FOUND:featureFlag ' + calleeName + '("tengu_keybinding_customization_release", !1)');
        break;
    }

    if ((secondArg.type === 'UnaryExpression' && secondArg.operator === '!' &&
         secondArg.argument.type === 'Literal' && secondArg.argument.value === 0) ||
        (secondArg.type === 'Literal' && secondArg.value === true)) {
        flagAlreadyPatched = true;
        console.log('FOUND:featureFlag already enabled');
        break;
    }

    if (secondArg.type === 'Literal' && secondArg.value === false) {
        fixes.featureFlag.found = true;
        fixes.featureFlag.node = secondArg;
        console.log('FOUND:featureFlag ' + calleeName + '("tengu_keybinding_customization_release", false)');
        break;
    }
}

if (!fixes.featureFlag.found && !flagAlreadyPatched) {
    console.error('NOT_FOUND:Unable to locate tengu_keybinding_customization_release feature flag');
    process.exit(1);
}

// ============================================================
// Patch 2: Change default ctrl+c binding from app:interrupt to app:exit
//
// Target AST: Property node where
//   key   = Literal "ctrl+c"
//   value = Literal "app:interrupt"
// inside the default bindings array (context: "Global")
// ============================================================

const ctrlCProps = findNodes(ast, n =>
    n.type === 'Property' &&
    n.key && n.key.type === 'Literal' && n.key.value === 'ctrl+c' &&
    n.value && n.value.type === 'Literal' && n.value.value === 'app:interrupt'
);

if (ctrlCProps.length > 0) {
    fixes.ctrlCBinding.found = true;
    fixes.ctrlCBinding.node = ctrlCProps[0].value;
    console.log('FOUND:ctrlCBinding "ctrl+c":"app:interrupt" -> will change to "app:exit"');
} else {
    // Check if already patched
    const patched = findNodes(ast, n =>
        n.type === 'Property' &&
        n.key && n.key.type === 'Literal' && n.key.value === 'ctrl+c' &&
        n.value && n.value.type === 'Literal' && n.value.value === 'app:exit'
    );
    if (patched.length > 0) {
        console.log('FOUND:ctrlCBinding already changed to app:exit');
    } else {
        console.error('NOT_FOUND:Unable to locate "ctrl+c":"app:interrupt" in default bindings');
        process.exit(1);
    }
}

// ============================================================
// Check results
// ============================================================

const needsPatch = Object.values(fixes).some(f => f.found);
if (!needsPatch) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = Object.values(fixes).filter(f => f.found).length;
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

// ============================================================
// Apply fixes
// ============================================================

let newCode = code;

function replaceAt(str, start, end, replacement) {
    return str.slice(0, start) + replacement + str.slice(end);
}

let replacements = [];

if (fixes.featureFlag.found && fixes.featureFlag.node) {
    const node = fixes.featureFlag.node;
    replacements.push({ start: node.start, end: node.end, replacement: '!0' });
    fixes.featureFlag.patched = true;
    console.log('PATCH:featureFlag - Changed default from !1 (false) to !0 (true)');
}

if (fixes.ctrlCBinding.found && fixes.ctrlCBinding.node) {
    const node = fixes.ctrlCBinding.node;
    replacements.push({ start: node.start, end: node.end, replacement: '"app:exit"' });
    fixes.ctrlCBinding.patched = true;
    console.log('PATCH:ctrlCBinding - Changed "ctrl+c" from "app:interrupt" to "app:exit"');
}

replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
}

// ============================================================
// Verify and save
// ============================================================

const patchedCount = Object.values(fixes).filter(f => f.patched).length;
if (patchedCount === 0) {
    console.error('VERIFY_FAILED:No fixes were applied');
    process.exit(1);
}

if (fixes.featureFlag.patched) {
    const expected = calleeName + '("tengu_keybinding_customization_release",!0)';
    if (!newCode.includes(expected)) {
        console.error('VERIFY_FAILED:Expected "' + expected + '" not found after patch');
        process.exit(1);
    }
}

if (fixes.ctrlCBinding.patched) {
    if (!newCode.includes('"ctrl+c":"app:exit"')) {
        console.error('VERIFY_FAILED:Expected "ctrl+c":"app:exit" not found after patch');
        process.exit(1);
    }
}

const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
PATCH_EOF

# ============================================================
# Execute patch script
# ============================================================
CHECK_ARG=""
if $CHECK_ONLY; then
    CHECK_ARG="--check"
fi

export BACKUP_SUFFIX
OUTPUT=$(node "$PATCH_SCRIPT" "$ACORN_PATH" "$CLI_PATH" "$CHECK_ARG" 2>&1) || true
EXIT_CODE=$?

rm -f "$PATCH_SCRIPT"

# ============================================================
# Process output
# ============================================================
while IFS= read -r line; do
    case "$line" in
        ALREADY_PATCHED)
            success "Already patched"
            exit 0
            ;;
        PARSE_ERROR:*)
            error "Failed to parse cli.js: ${line#PARSE_ERROR:}"
            exit 1
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
            echo ""
            info "Keybinding customization enabled. Ctrl+C now exits (Escape to interrupt)."
            ;;
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
