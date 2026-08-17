#!/bin/bash
#
# Claude Code Autocompact Override Fix Script
#
# Makes CLAUDE_AUTOCOMPACT_PCT_OVERRIDE work correctly as a percentage of
# TOTAL context window (not just available space).
#
# THREE ISSUES FIXED:
#
# 1. WHITELIST MISSING
#    Z_q() (init_safe_env) filters env vars through a whitelist Set.
#    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is NOT in the whitelist, so it never
#    reaches process.env during initialization.
#    FIX: Add the variable to the whitelist Set.
#
# 2. Math.min CAP
#    `return Math.min(w, K)` prevents raising the threshold above the default.
#    FIX: Change to `return w`.
#
# 3. WRONG PERCENTAGE BASE
#    `Math.floor(q * (z / 100))` uses `q` (available space = total - outputBuffer)
#    instead of total context window. Setting 95% yields ~85% of total context.
#    FIX: Replace `q` with the total context call (e.g. HP(A, DW())).
#
# DETECTION (pure AST):
#   - Whitelist: Find `new Set([...])` containing "MAX_THINKING_TOKENS"
#   - Autocompact fn: Find function containing "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
#   - Available space fn: Trace the first call in autocompact fn
#   - Total context: Extract LEFT side of the subtraction in available space fn
#
# Usage:
#   ./apply-claude-code-autocompact-override-fix.sh                    # Apply fix
#   ./apply-claude-code-autocompact-override-fix.sh /path/to/cli.js    # Specific file
#   ./apply-claude-code-autocompact-override-fix.sh --check            # Check only
#   ./apply-claude-code-autocompact-override-fix.sh --restore          # Restore backup
#

set -e

BACKUP_SUFFIX="backup-autocompact"

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
            echo "Fix CLAUDE_AUTOCOMPACT_PCT_OVERRIDE to work as % of total context window"
            echo ""
            echo "Fixes applied:"
            echo "  1. Add variable to init whitelist (so it reaches process.env)"
            echo "  2. Remove Math.min cap (so threshold can be raised)"
            echo "  3. Fix percentage base (use total context, not available space)"
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

# Download acorn parser if needed
ACORN_PATH="/tmp/acorn-claude-fix.js"
if [[ ! -f "$ACORN_PATH" ]]; then
    info "Downloading acorn parser..."
    curl -sL "https://unpkg.com/acorn@8.16.0/dist/acorn.js" -o "$ACORN_PATH" || {
        error "Failed to download acorn parser"
        exit 1
    }
fi

# Create patch script
PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);

const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup-autocompact';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

const src = (node) => code.slice(node.start, node.end);

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

// ============================================================
// Fix 1: Whitelist — Find the env var whitelist Set
// Pattern: new Set(["...", "MAX_THINKING_TOKENS", ...])
// ============================================================

let whitelistFix = { needed: false, arrayNode: null };

const newSetExprs = findNodes(ast, n =>
    n.type === 'NewExpression' &&
    n.callee.type === 'Identifier' &&
    n.callee.name === 'Set' &&
    n.arguments.length === 1 &&
    n.arguments[0].type === 'ArrayExpression'
);

for (const expr of newSetExprs) {
    const elems = expr.arguments[0].elements;
    const hasKnown = elems.some(e =>
        e.type === 'Literal' && e.value === 'MAX_THINKING_TOKENS'
    );
    if (!hasKnown) continue;

    const alreadyHas = elems.some(e =>
        e.type === 'Literal' && e.value === 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'
    );
    if (alreadyHas) {
        console.log('WHITELIST_OK:Already in whitelist');
    } else {
        whitelistFix.needed = true;
        whitelistFix.arrayNode = expr.arguments[0];
        console.log('FOUND:Whitelist Set (' + elems.length + ' entries), missing CLAUDE_AUTOCOMPACT_PCT_OVERRIDE');
    }
    break;
}

if (!whitelistFix.needed && !whitelistFix.arrayNode) {
    // Check if we found it at all
    const found = newSetExprs.some(expr => {
        const elems = expr.arguments[0].elements;
        return elems.some(e => e.type === 'Literal' && e.value === 'MAX_THINKING_TOKENS');
    });
    if (!found) {
        console.error('NOT_FOUND:Could not locate env var whitelist Set (expected new Set([..."MAX_THINKING_TOKENS"...]))');
        process.exit(1);
    }
}

// ============================================================
// Fix 2 & 3: Find autocompact function
// Anchor: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE string literal
// ============================================================

let mathMinFix = { needed: false, node: null, varName: null, var2Name: null };
let percentFix = { needed: false, leftNode: null, totalContextExpr: null };

const allFunctions = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' ||
    n.type === 'FunctionExpression' ||
    n.type === 'ArrowFunctionExpression'
);

let autocompactFn = null;

for (const fn of allFunctions) {
    if (!src(fn).includes('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')) continue;
    autocompactFn = fn;
    break;
}

if (!autocompactFn) {
    console.error('NOT_FOUND:No function contains CLAUDE_AUTOCOMPACT_PCT_OVERRIDE');
    process.exit(1);
}

const acParamName = autocompactFn.params?.[0]?.name;
console.log('FOUND:Autocompact function with param ' + acParamName);

// --- Fix 2: Find Math.min in return ---

const returnStmts = findNodes(autocompactFn, n => n.type === 'ReturnStatement');

for (const ret of returnStmts) {
    if (!ret.argument || ret.argument.type !== 'CallExpression') continue;
    const call = ret.argument;
    if (call.callee.type !== 'MemberExpression') continue;
    if (call.callee.object?.name !== 'Math' || call.callee.property?.name !== 'min') continue;
    if (call.arguments.length !== 2) continue;
    if (call.arguments[0].type !== 'Identifier' || call.arguments[1].type !== 'Identifier') continue;

    mathMinFix.needed = true;
    mathMinFix.node = call;
    mathMinFix.varName = call.arguments[0].name;
    mathMinFix.var2Name = call.arguments[1].name;
    console.log('FOUND:return Math.min(' + mathMinFix.varName + ', ' + mathMinFix.var2Name + ')');
    break;
}

if (!mathMinFix.needed) {
    console.log('MATHMIN_OK:Math.min already removed');
}

// --- Fix 3: Find Math.floor percentage base ---

const mathFloorCalls = findNodes(autocompactFn, n =>
    n.type === 'CallExpression' &&
    n.callee.type === 'MemberExpression' &&
    n.callee.object?.name === 'Math' &&
    n.callee.property?.name === 'floor' &&
    n.arguments.length === 1 &&
    n.arguments[0].type === 'BinaryExpression' &&
    n.arguments[0].operator === '*'
);

for (const fc of mathFloorCalls) {
    const mulExpr = fc.arguments[0];

    if (mulExpr.left.type === 'Identifier') {
        // Left is a simple variable (available space) — needs patching
        percentFix.leftNode = mulExpr.left;
        const availVarName = mulExpr.left.name;
        console.log('FOUND:Math.floor(' + availVarName + ' * ...) — percentage base is available space');

        // Trace: find what function initializes this variable
        const varDecls = findNodes(autocompactFn.body, n =>
            n.type === 'VariableDeclarator' &&
            n.id.type === 'Identifier' &&
            n.id.name === availVarName &&
            n.init?.type === 'CallExpression' &&
            n.init.callee?.type === 'Identifier'
        );

        if (varDecls.length === 0) {
            console.error('NOT_FOUND:Cannot trace variable ' + availVarName + ' to a function call');
            process.exit(1);
        }

        const availFuncName = varDecls[0].init.callee.name;
        console.log('FOUND:' + availVarName + ' = ' + availFuncName + '(' + acParamName + ')');

        // Find the available space function definition
        const availFuncs = findNodes(ast, n =>
            n.type === 'FunctionDeclaration' &&
            n.id.name === availFuncName &&
            n.params.length === 1
        );

        if (availFuncs.length === 0) {
            console.error('NOT_FOUND:Function ' + availFuncName + ' not found');
            process.exit(1);
        }

        const availFn = availFuncs[0];
        const availParam = availFn.params[0].name;
        const availRets = findNodes(availFn.body, n => n.type === 'ReturnStatement');

        if (availRets.length === 0 || !availRets[0].argument) {
            console.error('NOT_FOUND:No return in ' + availFuncName);
            process.exit(1);
        }

        const retArg = availRets[0].argument;

        // Expect: totalContextCall - outputBufferExpr
        if (retArg.type !== 'BinaryExpression' || retArg.operator !== '-') {
            console.error('NOT_FOUND:' + availFuncName + ' return is not a subtraction');
            process.exit(1);
        }

        // LEFT = total context call (e.g. HP(A, DW()))
        let tcExpr = src(retArg.left);

        // Substitute parameter name if different
        if (availParam !== acParamName) {
            tcExpr = tcExpr.replace(
                new RegExp('\\b' + availParam + '\\b', 'g'),
                acParamName
            );
        }

        percentFix.needed = true;
        percentFix.totalContextExpr = tcExpr;
        console.log('FOUND:Total context expression: ' + tcExpr);
        break;

    } else if (mulExpr.left.type === 'CallExpression') {
        // Left is already a function call — likely already patched
        console.log('PERCENT_OK:Percentage base already patched (' + src(mulExpr.left).slice(0, 40) + ')');
        break;
    }
}

// ============================================================
// Status check
// ============================================================

const patchCount = (whitelistFix.needed ? 1 : 0) +
                   (mathMinFix.needed ? 1 : 0) +
                   (percentFix.needed ? 1 : 0);

if (patchCount === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

console.log('PATCH_NEEDED:' + patchCount + ' fix(es) to apply');

if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchCount);
    process.exit(1);
}

// ============================================================
// Apply patches (collect, sort by offset descending, apply)
// ============================================================

const patches = [];

if (whitelistFix.needed) {
    const lastElem = whitelistFix.arrayNode.elements[
        whitelistFix.arrayNode.elements.length - 1
    ];
    patches.push({
        start: lastElem.end,
        end: lastElem.end,
        insert: ',"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"',
        desc: 'Add CLAUDE_AUTOCOMPACT_PCT_OVERRIDE to whitelist'
    });
}

if (mathMinFix.needed) {
    patches.push({
        start: mathMinFix.node.start,
        end: mathMinFix.node.end,
        insert: mathMinFix.varName,
        desc: 'Math.min(' + mathMinFix.varName + ', ' + mathMinFix.var2Name + ') -> ' + mathMinFix.varName
    });
}

if (percentFix.needed) {
    patches.push({
        start: percentFix.leftNode.start,
        end: percentFix.leftNode.end,
        insert: percentFix.totalContextExpr,
        desc: 'Percentage base: ' + src(percentFix.leftNode) + ' -> ' + percentFix.totalContextExpr
    });
}

// Sort descending by start offset (apply from end to preserve positions)
patches.sort((a, b) => b.start - a.start);

let newCode = code;
for (const p of patches) {
    newCode = newCode.slice(0, p.start) + p.insert + newCode.slice(p.end);
    console.log('PATCH:' + p.desc);
}

// Backup and save
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchCount);
PATCH_EOF

CHECK_ARG=""
if $CHECK_ONLY; then
    CHECK_ARG="--check"
fi

export BACKUP_SUFFIX
OUTPUT=$(node "$PATCH_SCRIPT" "$ACORN_PATH" "$CLI_PATH" "$CHECK_ARG" 2>&1) || true
EXIT_CODE=$?

rm -f "$PATCH_SCRIPT"

while IFS= read -r line; do
    case "$line" in
        ALREADY_PATCHED)
            success "All fixes already applied"
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
        WHITELIST_OK:*|MATHMIN_OK:*|PERCENT_OK:*)
            success "${line#*:}"
            ;;
        PATCH_NEEDED:*)
            info "${line#PATCH_NEEDED:}"
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
            success "Fix applied! (${line#SUCCESS:} patch(es))"
            echo ""
            echo "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE now works as % of TOTAL context window."
            echo "Example: PCT_OVERRIDE=95 → autocompact at 95% of total context"
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
