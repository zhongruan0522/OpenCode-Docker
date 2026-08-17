#!/bin/bash
#
# Claude Code Disable Read/Search Collapsing Fix Script
#
# PURPOSE:
# Restores v2.1.19-style individual tool call display by disabling the
# collapsing of consecutive Read/Search operations into a single summary
# line like "Read 2 files (ctrl+o to expand)".
#
# THE BUG (v2.1.20+):
# Starting from v2.1.20, consecutive Read/Search tool calls are collapsed
# into a single aggregated line, hiding per-file details:
#   Before (v2.1.19): Each call shown with file name + result
#     ⏺ Read(package.json)
#     ⎿ Read 31 lines
#     ⏺ Search(pattern: "useEffect", path: "src/")
#     ⎿ Found 12 matches across 5 files
#   After (v2.1.20+): Collapsed into summary
#     ⏺ Read 2 files, Searched for 1 pattern (ctrl+o to expand)
#
# ROOT CAUSE:
# In v2.1.19, the collapsed group builder function had `return A;` as its
# first statement, making the collapsing logic dead code. v2.1.20 removed
# this early return, activating the collapsing behavior.
#
# FIX:
# Re-insert `return <firstParam>;` at the beginning of the builder function
# body, restoring the v2.1.19 pass-through behavior.
#
# DETECTION STRATEGY (AST-based, version-agnostic):
# 1) Find "collapsed_read_search" string literal
# 2) Locate the enclosing 1-param creator function (returns {type:"collapsed_read_search",...})
# 3) Find the builder function (next FunctionDeclaration that calls the creator)
# 4) Check if already patched (first stmt is return <firstParam>)
# 5) Inject `return <firstParam>;` after the builder's opening brace
#
# Verified: v2.1.19 ~ v2.1.42
#
# Usage:
#   ./apply-claude-code-disable-collapse-read-search-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-disable-collapse-read-search-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-disable-collapse-read-search-fix.sh --check            # Check only
#   ./apply-claude-code-disable-collapse-read-search-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-collapse-rs"
FIX_DESCRIPTION="Disable collapsing of consecutive Read/Search tool calls"

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
# Node.js patch script
# ============================================================
PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
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

// Version info (informational)
const versionMatch = code.slice(0, 500).match(/Version:\s*([\d.]+)/);
console.log('VERSION:' + (versionMatch ? versionMatch[1] : 'unknown'));

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// AST helpers
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

const src = (node) => code.slice(node.start, node.end);

// ============================================================
// Step 1: Find "collapsed_read_search" string literals
// ============================================================
console.log('STEP:1 - Finding "collapsed_read_search" literals');

const collapsedLiterals = findNodes(ast, n =>
    n.type === 'Literal' && n.value === 'collapsed_read_search'
);

if (collapsedLiterals.length === 0) {
    console.error('NOT_FOUND:No "collapsed_read_search" string literal in code');
    process.exit(1);
}

console.log('FOUND:' + collapsedLiterals.length + ' "collapsed_read_search" literals');

// ============================================================
// Step 2: Find the creator function
// A FunctionDeclaration with 1 param that returns
// {type: "collapsed_read_search", ...}
// ============================================================
console.log('STEP:2 - Finding creator function');

const allFuncDecls = findNodes(ast, n => n.type === 'FunctionDeclaration');

let creatorFunc = null;
for (const literal of collapsedLiterals) {
    // Find enclosing FunctionDeclaration with 1 param
    const enclosing = allFuncDecls.find(fn =>
        fn.start <= literal.start && fn.end >= literal.end &&
        fn.params.length === 1
    );
    if (!enclosing) continue;

    // Validate: contains ObjectExpression with Property type:"collapsed_read_search"
    // The object may be in a ReturnStatement (older versions) or
    // assigned to a variable then returned (v2.1.49+)
    const objExprs = findNodes(enclosing.body, n => n.type === 'ObjectExpression');
    const hasTypeProperty = objExprs.some(obj =>
        obj.properties.some(p => {
            const keyName = p.key?.name || p.key?.value;
            return keyName === 'type' &&
                   p.value?.type === 'Literal' &&
                   p.value.value === 'collapsed_read_search';
        })
    );

    // Also verify it accesses A.messages[0] (creator signature)
    const bodySrc = src(enclosing.body);
    const hasMessageAccess = bodySrc.includes('.messages[0]') ||
                             bodySrc.includes('.messages[0]');

    if (hasTypeProperty && hasMessageAccess) {
        creatorFunc = enclosing;
        break;
    }
}

if (!creatorFunc) {
    console.error('NOT_FOUND:Cannot identify collapsed_read_search creator function');
    process.exit(1);
}

console.log('FOUND:creator = ' + creatorFunc.id.name + '(' +
            creatorFunc.params.map(p => p.name).join(',') + ') at offset ' +
            creatorFunc.start);

// ============================================================
// Step 3: Find the builder function
// The OUTERMOST FunctionDeclaration containing the creator call.
// The creator is called from a nested inner flush function inside
// the builder, so we must find the outermost enclosing function.
// ============================================================
console.log('STEP:3 - Finding builder function');

const creatorCallPattern = creatorFunc.id.name + '(';

// Find all FunctionDeclarations whose source contains the creator call
const callerFuncs = allFuncDecls.filter(fn => {
    if (fn === creatorFunc) return false;
    if (fn.end < creatorFunc.start) return false;
    return src(fn).includes(creatorCallPattern);
});

// Find the outermost: the one not nested inside any other caller
let builderFunc = null;
for (const fn of callerFuncs) {
    const isNested = callerFuncs.some(other =>
        other !== fn &&
        other.start <= fn.start && other.end >= fn.end
    );
    if (!isNested) {
        builderFunc = fn;
        break;
    }
}

if (!builderFunc) {
    console.error('NOT_FOUND:Cannot find builder function (caller of ' +
                  creatorFunc.id.name + ')');
    process.exit(1);
}

console.log('FOUND:builder = ' + builderFunc.id.name + '(' +
            builderFunc.params.map(p => p.name).join(',') + ') at offset ' +
            builderFunc.start + ' [' + (builderFunc.end - builderFunc.start) + ' bytes]');

// ============================================================
// Step 4: Check if already patched
// First body statement is `return <firstParam>;`
// ============================================================
console.log('STEP:4 - Checking if already patched');

const firstParamName = builderFunc.params[0].name;
const bodyStmts = builderFunc.body.body;
const firstStmt = bodyStmts[0];

if (firstStmt &&
    firstStmt.type === 'ReturnStatement' &&
    firstStmt.argument &&
    firstStmt.argument.type === 'Identifier' &&
    firstStmt.argument.name === firstParamName) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

console.log('FOUND:collapse-fix - Builder needs early return of "' + firstParamName + '"');

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:1');
    process.exit(1);
}

// ============================================================
// Step 5: Apply patch - inject `return <firstParam>;`
// ============================================================
let newCode = code;

function replaceAt(str, start, end, replacement) {
    return str.slice(0, start) + replacement + str.slice(end);
}

const insertionPoint = builderFunc.body.start + 1; // right after '{'
const insertion = 'return ' + firstParamName + ';';

newCode = replaceAt(newCode, insertionPoint, insertionPoint, insertion);
console.log('PATCH:collapse-fix - Injected "' + insertion + '" at offset ' + insertionPoint);

// ============================================================
// Step 6: Verify
// ============================================================

// 6a. Re-parse to confirm syntax is valid
try {
    acorn.parse(newCode, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 6b. Content verification at injection point
const patchedSnippet = newCode.slice(insertionPoint, insertionPoint + insertion.length);
if (patchedSnippet !== insertion) {
    console.error('VERIFY_FAILED:Early return not found at injection point');
    process.exit(1);
}

// 6c. Re-parse AST and verify first statement
const newAst = acorn.parse(newCode, { ecmaVersion: "latest", sourceType: 'module' });
const newFuncDecls = findNodes(newAst, n => n.type === 'FunctionDeclaration');
// Find the builder by position (may shift slightly due to insertion)
const newBuilder = newFuncDecls.find(fn =>
    fn.start >= builderFunc.start && fn.start <= builderFunc.start + insertion.length + 5
);
if (newBuilder) {
    const newFirst = newBuilder.body.body[0];
    if (!newFirst ||
        newFirst.type !== 'ReturnStatement' ||
        !newFirst.argument ||
        newFirst.argument.type !== 'Identifier' ||
        newFirst.argument.name !== firstParamName) {
        console.error('VERIFY_FAILED:Builder first statement is not return ' + firstParamName);
        process.exit(1);
    }
    console.log('VERIFY:AST re-parse confirms early return in ' + newBuilder.id.name + '()');
} else {
    // Non-critical: position-based lookup may fail, content check passed
    console.log('VERIFY:Content check passed (AST position lookup skipped)');
}

// ============================================================
// Backup and write
// ============================================================
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:1');
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
            success "Already patched (collapsing already disabled)"
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
        VERSION:*)
            info "Claude Code version: ${line#VERSION:}"
            ;;
        STEP:*)
            info "Step ${line#STEP:}"
            ;;
        FOUND:*)
            info "Found: ${line#FOUND:}"
            ;;
        VERIFY:*)
            info "Verify: ${line#VERIFY:}"
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
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
