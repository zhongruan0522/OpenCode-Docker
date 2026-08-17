#!/bin/bash
#
# Claude Code Cleanup Period Default Override Fix Script
#
# PURPOSE:
# Changes the default cleanupPeriodDays from 30 to 9999 (~27 years),
# effectively disabling automatic cleanup of chat transcripts, logs,
# plans, file history, session env, debug logs, and paste cache.
#
# BACKGROUND:
# Claude Code's cleanup subsystem uses cleanupPeriodDays (default: 30)
# to determine the retention period for 7 categories of user data.
# Setting it to 0 via settings is NOT recommended — it disables session
# persistence entirely (no new transcripts written).
# This script changes the hardcoded default so that users who haven't
# explicitly configured cleanupPeriodDays get near-permanent retention.
#
# WHAT IT PATCHES:
# 1) The default constant (e.g. LDz=30 → LDz=9999) used when
#    settings.cleanupPeriodDays is not explicitly set by the user.
#
# DETECTION STRATEGY (AST-based, version-agnostic):
# 1. Parse cli.js with acorn into AST
# 2. Find BinaryExpression: <id> * 24 * 60 * 60 * 1000
#    where <id> is the right side of a NullishCoalescingExpression
#    whose left is MemberExpression .cleanupPeriodDays
# 3. Extract the constant name <id> from that expression
# 4. Find VariableDeclarator: <id> = 30
# 5. Replace the Literal 30 → 9999 at precise AST position
#
# Verified compatible:
#   v2.0.76 (OW7=30)
#   v2.1.42 (LDz=30)
#
# Usage:
#   ./apply-claude-code-cleanup-period-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-cleanup-period-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-cleanup-period-fix.sh --check            # Check only
#   ./apply-claude-code-cleanup-period-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-cleanup-period"
FIX_DESCRIPTION="Change cleanupPeriodDays default from 30 to 9999 (disable automatic cleanup)"

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
# Determine CLI_PATH
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

const NEW_VALUE = 9999;
const EXPECTED_OLD_VALUE = 30;

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

// Track fix status
let fixes = {
    cleanupDefault: { found: false, patched: false, node: null }
};

// Parse AST
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// AST helper: find nodes matching predicate
function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
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

// Get source code snippet from AST node
const src = (node) => code.slice(node.start, node.end);

// ============================================================
// Step 1: Find the NullishCoalescing usage site via AST
//
// Target AST shape (the tY1/yfA function body):
//   BinaryExpression {
//     left: BinaryExpression {
//       left: BinaryExpression {
//         left: BinaryExpression {
//           left: LogicalExpression {        ← ?? operator
//             operator: "??",
//             left: MemberExpression {       ← *.cleanupPeriodDays
//               property.name: "cleanupPeriodDays"
//             },
//             right: Identifier { name: <CONST> }  ← the default constant
//           },
//           operator: "*",
//           right: Literal { value: 24 }
//         },
//         operator: "*",
//         right: Literal { value: 60 }
//       },
//       operator: "*",
//       right: Literal { value: 60 }
//     },
//     operator: "*",
//     right: Literal { value: 1000 }
//   }
// ============================================================

// Find all LogicalExpression with ?? operator and cleanupPeriodDays
const nullishExprs = findNodes(ast, n =>
    n.type === 'LogicalExpression' &&
    n.operator === '??' &&
    n.left &&
    n.left.type === 'MemberExpression' &&
    n.left.property &&
    n.left.property.type === 'Identifier' &&
    n.left.property.name === 'cleanupPeriodDays' &&
    n.right &&
    n.right.type === 'Identifier'
);

if (nullishExprs.length === 0) {
    console.error('NOT_FOUND:Cannot locate cleanupPeriodDays ?? <const> expression in AST');
    process.exit(1);
}

const nullishExpr = nullishExprs[0];
const constName = nullishExpr.right.name;
console.log('FOUND:usage site -> .cleanupPeriodDays ?? ' + constName + ' (in * 24 * 60 * 60 * 1000 expression)');

// ============================================================
// Step 2: Find the VariableDeclarator for the constant via AST
//
// Target AST shape:
//   VariableDeclarator {
//     id: Identifier { name: <CONST> },
//     init: Literal { value: 30 }
//   }
// ============================================================

const varDeclarators = findNodes(ast, n =>
    n.type === 'VariableDeclarator' &&
    n.id &&
    n.id.type === 'Identifier' &&
    n.id.name === constName &&
    n.init &&
    n.init.type === 'Literal' &&
    typeof n.init.value === 'number'
);

if (varDeclarators.length === 0) {
    console.error('NOT_FOUND:Cannot locate VariableDeclarator for ' + constName + ' with numeric Literal init');
    process.exit(1);
}

const declarator = varDeclarators[0];
const currentValue = declarator.init.value;
const initNode = declarator.init;

console.log('FOUND:declaration -> ' + constName + ' = ' + currentValue + ' (at offset ' + initNode.start + '-' + initNode.end + ')');

// Check if already patched
if (currentValue === NEW_VALUE) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

// Safety: verify the current value is what we expect
if (currentValue !== EXPECTED_OLD_VALUE) {
    console.error('NOT_FOUND:Unexpected default value ' + currentValue + ' (expected ' + EXPECTED_OLD_VALUE + '). Aborting to avoid corrupting unknown code.');
    process.exit(1);
}

fixes.cleanupDefault.found = true;
fixes.cleanupDefault.node = initNode;

if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:1');
    process.exit(1);
}

// ============================================================
// Step 3: Apply fix using AST node positions
// Replace the Literal node (value 30) with 9999
// ============================================================

let newCode = code;

function replaceAt(str, start, end, replacement) {
    return str.slice(0, start) + replacement + str.slice(end);
}

let replacements = [];

if (fixes.cleanupDefault.found && fixes.cleanupDefault.node) {
    const node = fixes.cleanupDefault.node;
    replacements.push({
        start: node.start,
        end: node.end,
        replacement: String(NEW_VALUE),
        name: 'cleanupDefault'
    });
    fixes.cleanupDefault.patched = true;
    console.log('PATCH:cleanup-period-default - Changed ' + constName + '=' + EXPECTED_OLD_VALUE + ' to ' + constName + '=' + NEW_VALUE + ' (AST Literal at ' + node.start + '-' + node.end + ')');
}

// Apply replacements from end to start to preserve positions
replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
}

// ============================================================
// Verify the patch
// ============================================================

const patchedCount = Object.values(fixes).filter(f => f.patched).length;
if (patchedCount === 0) {
    console.error('VERIFY_FAILED:No fixes were applied');
    process.exit(1);
}

// Re-parse to verify structural integrity
try {
    acorn.parse(newCode, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// Backup original file
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

// Write patched file
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
            success "Already patched (default is already 9999)"
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
            info "Default cleanupPeriodDays: 30 -> 9999 (~27 years)"
            info "Affects: transcripts, error/MCP/debug logs, plans, file-history, session-env, paste-cache"
            info "Note: Users who explicitly set cleanupPeriodDays in settings are NOT affected"
            echo ""
            warning "Restart Claude Code for changes to take effect"
            ;;
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
