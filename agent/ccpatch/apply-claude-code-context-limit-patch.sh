#!/bin/bash
#
# Claude Code Context Limit Override Patch Script
#
# PURPOSE:
# Makes the hardcoded 200000 (200K) context window limit configurable via
# the CLAUDE_CODE_CONTEXT_LIMIT environment variable.
#
# THE BUG:
# Claude Code hardcodes 200000 tokens as the default context window in multiple
# places throughout cli.js. Users cannot override this without modifying the
# source code.
#
# FIX:
# Replaces specific 200000 variable declarations with:
#   (+process.env.CLAUDE_CODE_CONTEXT_LIMIT||200000)
#
# PATCHED LOCATIONS (v2.1.140 verified):
# 1) h8K = 200000      → hook evaluator transcript truncation limit
# 2) tF_ = 200000      → tool-call context window limit
# 3) o4O = 200000      → slash command skill listing budget base
# 4) F93 = 200000      → session state JSON batch split byte limit
# 5) "> 200000" literal → large message detection threshold
#
# NOT PATCHED (intentionally):
# - Comment/doc string occurrences (e.g., "max_input_tokens": 200000)
# - User-facing prompt text examples
#
# DETECTION STRATEGY (AST-based + targeted regex):
# 1) Parse AST to find variable declarations with numeric literal 200000
# 2) Validate each match is a top-level var assignment (not nested in a function call arg)
# 3) Replace the numeric literal with the configurable expression
# 4) Also replace the standalone > 200000 comparison pattern
#
# Usage:
#   ./apply-claude-code-context-limit-patch.sh                    # Apply patch (auto-detect)
#   ./apply-claude-code-context-limit-patch.sh /path/to/cli.js   # Apply to specific file
#   ./apply-claude-code-context-limit-patch.sh --check           # Check only
#   ./apply-claude-code-context-limit-patch.sh --restore         # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-ctxlimit"
FIX_DESCRIPTION="Make context window limit configurable via CLAUDE_CODE_CONTEXT_LIMIT env var"

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
ACORN_PATH="$HOME/acorn-claude-fix.js"
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

// Version info (informational) - check multiple patterns
const versionMatch = code.slice(0, 1000).match(/Version:\s*([\d.]+)/)
    || code.match(/VERSION:\s*"([\d.]+)"/)
    || code.match(/"version"\s*:\s*"([\d.]+)"/);
console.log('VERSION:' + (versionMatch ? versionMatch[1] : 'unknown'));

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
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
// Phase 1: Find 200000 numeric literals and classify
// ============================================================

console.log('STEP:1 - Finding 200000 numeric literals');

const numericLiterals = findNodes(ast, n =>
    n.type === 'Literal' && typeof n.value === 'number' && n.value === 200000
);

console.log('FOUND:' + numericLiterals.length + ' occurrences of numeric literal 200000');

// Build parent map
const parentMap = new Map();
function buildParentMap(node, parent) {
    if (!node || typeof node !== 'object') return;
    if (node.type) parentMap.set(node, parent);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => buildParentMap(child, node));
            } else {
                buildParentMap(node[key], node);
            }
        }
    }
}
buildParentMap(ast, null);

console.log('STEP:2 - Classifying literals by parent AST node');

const replacements = [];
const contextVarNames = [];  // collect var names for Phase 3 injection
let patchedCount = 0;
let skippedCount = 0;

const replacement = '(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||200000)';

for (const lit of numericLiterals) {
    const parent = parentMap.get(lit);
    const grandparent = parent ? parentMap.get(parent) : null;
    let context = 'unknown';
    let shouldPatch = false;
    let varName = null;

    // Pattern 1: Top-level VariableDeclarator init
    if (parent && parent.type === 'VariableDeclarator' && parent.init === lit) {
        if (grandparent && grandparent.type === 'VariableDeclaration') {
            const isTopLevel = ast.body.includes(grandparent);
            if (isTopLevel) {
                varName = parent.id.name;
                context = 'top-level-var(' + varName + ')';
                shouldPatch = true;
                contextVarNames.push(varName);
            }
        }
    }

    // Pattern 2: BinaryExpression comparison operand
    if (!shouldPatch && parent && parent.type === 'BinaryExpression' && parent.right === lit) {
        const cmpOps = ['>', '<', '>=', '<=', '==', '!=', '===', '!=='];
        if (cmpOps.includes(parent.operator)) {
            context = 'comparison(' + parent.operator + ')';
            shouldPatch = true;
        }
    }

    // Pattern 3: LEFT operand of a comparison
    if (!shouldPatch && parent && parent.type === 'BinaryExpression' && parent.left === lit) {
        const cmpOps = ['>', '<', '>=', '<=', '==', '!=', '===', '!=='];
        if (cmpOps.includes(parent.operator)) {
            context = 'comparison-left(' + parent.operator + ')';
            shouldPatch = true;
        }
    }

    if (shouldPatch) {
        const label = varName || context;
        console.log('  [PATCH] ' + label + ' at offset ' + lit.start);
        replacements.push({
            start: lit.start,
            end: lit.end,
            replacement,
            context,
            varName
        });
        patchedCount++;
    } else {
        skippedCount++;
        const preview = code.slice(Math.max(0, lit.start - 30), lit.end + 20).replace(/\n/g, '\\n');
        console.log('  [SKIP]  unknown context at offset ' + lit.start + ': ...' + preview + '...');
    }
}

console.log('VAR_NAMES_FOR_REASSIGN:' + JSON.stringify(contextVarNames));
console.log(`\nSUMMARY: ${patchedCount} will be patched, ${skippedCount} skipped`);

if (patchedCount === 0) {
    console.error('NOT_FOUND:No patchable 200000 literals found');
    process.exit(1);
}

// ============================================================
// Phase 2: Find env-loading functions (Ay8 and Ui analogues)
//
// Detection strategy (AST structure, name-agnostic):
//   1) Find all FunctionDeclarations whose body contains
//      Object.assign(process.env, ...)
//   2) Ay8 = the one with ForOfStatement (has for...of loops)
//   3) Ui  = the one without ForOfStatement (just assign + call chain)
// ============================================================

console.log('STEP:3 - Finding env-loading functions');

function hasProcessEnvAssign(funcNode) {
    const assignCalls = findNodes(funcNode, n =>
        n.type === 'CallExpression' &&
        n.callee?.type === 'MemberExpression' &&
        n.callee.object?.name === 'Object' &&
        n.callee.property?.name === 'assign' &&
        n.arguments?.length >= 2 &&
        n.arguments[0]?.type === 'MemberExpression' &&
        n.arguments[0].object?.name === 'process' &&
        n.arguments[0].property?.name === 'env'
    );
    return assignCalls.length > 0;
}

const allFuncDecls = findNodes(ast, n => n.type === 'FunctionDeclaration');

const envLoaderFuncs = allFuncDecls.filter(fn => hasProcessEnvAssign(fn));

if (envLoaderFuncs.length < 2) {
    console.error('NOT_FOUND:Cannot find env-loading functions (found ' + envLoaderFuncs.length + ', need >= 2)');
    process.exit(1);
}

for (const fn of envLoaderFuncs) {
    console.log('FOUND:env-loader = ' + fn.id.name + ' at offset ' + fn.start + ' [' + (fn.end - fn.start) + ' bytes]');
}

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchedCount);
    console.log('ENV_LOADERS:' + envLoaderFuncs.map(fn => fn.id.name).join(','));
    console.log('VAR_NAMES:' + JSON.stringify(contextVarNames));
    process.exit(1);
}

// ============================================================
// Phase 3: Apply patches
//
// 3a: Replace 200000 literals (reverse order to preserve positions)
// 3b: Inject re-assignment code at end of Ay8 and Ui
// ============================================================

let newCode = code;

function replaceAt(str, start, end, replacement) {
    return str.slice(0, start) + replacement + str.slice(end);
}

// 3b: Collect env-loader injection points (AST body.end - 1 = before closing brace)
const reassignExpr = '(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||';
const reassignStmts = contextVarNames
    .map(name => name + '=' + reassignExpr + name + ')')
    .join(';');

for (const fn of envLoaderFuncs) {
    // body.end points to the char AFTER '}', so body.end - 1 = the '}' itself
    const insertAt = fn.body.end - 1;
    replacements.push({
        start: insertAt,
        end: insertAt,
        replacement: ';' + reassignStmts + ';',
        context: 'env-inject(' + fn.id.name + ')',
        varName: null
    });
    patchedCount++;
    console.log('PATCH:inject:' + fn.id.name + ' - Will inject at AST body.end-1 (offset ' + insertAt + ')');
}

// 3c: Apply ALL replacements (literals + injections) in one pass, reverse order
replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
    console.log('PATCH:' + r.context + (r.varName ? ' (' + r.varName + ')' : '') + ' at offset ' + r.start);
}

// ============================================================
// Phase 4: Verify via AST re-parse
// ============================================================

let newAst;
try {
    newAst = acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST re-parse confirms valid syntax');
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 4b. Verify env-var expressions exist in AST (MemberExpression process.env.CLAUDE_CODE_CONTEXT_LIMIT)
const envRefNodes = findNodes(newAst, n =>
    n.type === 'MemberExpression' &&
    n.object?.type === 'MemberExpression' &&
    n.object.object?.name === 'process' &&
    n.object.property?.name === 'env' &&
    n.property?.name === 'CLAUDE_CODE_CONTEXT_LIMIT'
);
console.log('VERIFY:process.env.CLAUDE_CODE_CONTEXT_LIMIT refs in AST: ' + envRefNodes.length);
if (envRefNodes.length < patchedCount) {
    console.error('VERIFY_FAILED:Expected >= ' + patchedCount + ' env refs, found ' + envRefNodes.length);
    process.exit(1);
}

// 4c. Verify each env-loader function now contains re-assignment
for (const fn of envLoaderFuncs) {
    const patchedFn = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id?.name === fn.id.name
    )[0];
    if (!patchedFn) {
        console.error('VERIFY_FAILED:' + fn.id.name + ' not found after patch');
        process.exit(1);
    }
    const hasEnvRef = findNodes(patchedFn, n =>
        n.type === 'MemberExpression' &&
        n.object?.type === 'MemberExpression' &&
        n.object.object?.name === 'process' &&
        n.object.property?.name === 'env' &&
        n.property?.name === 'CLAUDE_CODE_CONTEXT_LIMIT'
    ).length > 0;
    if (!hasEnvRef) {
        console.error('VERIFY_FAILED:' + fn.id.name + ' missing CLAUDE_CODE_CONTEXT_LIMIT ref after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + fn.id.name + ' has CLAUDE_CODE_CONTEXT_LIMIT re-assignment');
}

// ============================================================
// Backup and write
// ============================================================
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
            success "Already patched (context limit already configurable)"
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
        SUMMARY:*)
            info "Summary: ${line#SUMMARY:}"
            ;;
        VERIFY:*)
            info "Verify: ${line#VERIFY:}"
            ;;
        PATCH:literal:*)
            info "  Literal: ${line#PATCH:literal:}"
            ;;
        PATCH:reassign:*)
            info "  ${line#PATCH:reassign:}"
            ;;
        PATCH:inject:*)
            info "  ${line#PATCH:inject:}"
            ;;
        VAR_NAMES_FOR_REASSIGN:*)
            info "Context-limit variables: ${line#VAR_NAMES_FOR_REASSIGN:}"
            ;;
        \ \ \[*)
            # Detail lines from script output
            echo "    $line"
            ;;
        NEEDS_PATCH)
            echo ""
            warning "Patch needed - run without --check to apply"
            ;;
        ENV_LOADERS:*)
            info "Env-loader functions: ${line#ENV_LOADERS:}"
            ;;
        VAR_NAMES:*)
            info "Variables to reassign: ${line#VAR_NAMES:}"
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
            echo "Usage: CLAUDE_CODE_CONTEXT_LIMIT=500000 claude"
            ;;
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
