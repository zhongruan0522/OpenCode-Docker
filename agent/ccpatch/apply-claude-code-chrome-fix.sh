#!/bin/bash
#
# Claude Code Bridge Socket Fallback Fix Script
#
# THE ISSUE:
# Claude Code's MCP browser client always uses WebSocket bridge (requires OAuth),
# even when a local Unix socket / Named Pipe is available from the Chrome extension's
# native host. This prevents API Key mode users from using browser tools.
#
# ROOT CAUSE:
# In B4_(config), bridgeConfig is always present, so ei6() (WebSocket BridgeClient)
# is always chosen. The getSocketPaths (Unix Socket) and ri6() (Native Messaging)
# paths are dead code:
#   return H.bridgeConfig ? ei6(H) : H.getSocketPaths ? uFA(H) : ri6(H)
#
# FIX:
# Create a composite client that tries BridgeClient first, and falls back to
# SocketClient (uFA) when bridge connection fails (no OAuth token / no userId).
#
# Usage:
#   ./apply-claude-code-bridge-socket-fallback.sh                    # Apply fix
#   ./apply-claude-code-bridge-socket-fallback.sh /path/to/cli.js    # Specific file
#   ./apply-claude-code-bridge-socket-fallback.sh --check            # Check only
#   ./apply-claude-code-bridge-socket-fallback.sh --restore          # Restore backup
#

set -e

BACKUP_SUFFIX="backup-bridge-fallback"
FIX_DESCRIPTION="Enable socket fallback when WebSocket bridge fails (for API Key mode)"

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
            echo "$FIX_DESCRIPTION"
            echo ""
            echo "Options:"
            echo "  --check, -c    Check if fix is needed"
            echo "  --restore, -r  Restore from backup"
            echo "  --help, -h     Show help"
            exit 0
            ;;
        -*) error "Unknown option: $1"; exit 1 ;;
        *) if [[ -z "$CLI_PATH_ARG" ]]; then CLI_PATH_ARG="$1"; else error "Unexpected: $1"; exit 1; fi; shift ;;
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
        error "File not found: $CLI_PATH_ARG"
        exit 1
    fi
else
    CLI_PATH=$(find_cli_path) || {
        error "Claude Code cli.js not found"
        echo ""
        echo "Tip: Specify the path directly:"
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
        error "No backup found"
        exit 1
    fi
fi

echo ""

ACORN_PATH="/tmp/acorn-claude-fix.js"
if [[ ! -f "$ACORN_PATH" ]]; then
    info "Downloading acorn parser..."
    curl -sL "https://unpkg.com/acorn@8.16.0/dist/acorn.js" -o "$ACORN_PATH" || {
        error "Failed to download acorn"
        exit 1
    }
fi

PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

let fixes = {
    clientFactory: { found: false, patched: false, node: null },
    subscriptionGate: { found: false, patched: false, node: null },
    subscriptionMsg: { found: false, patched: false, node: null },
    selectBrowserHide: { found: false, patched: false, node: null }
};

// Parse AST
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

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
// Find B4_() — the client factory function
// Structural pattern:
//   function XXX(H) {
//     return H.bridgeConfig ? YYY(H) : H.getSocketPaths ? ZZZ(H) : WWW(H)
//   }
// This is a function with:
//   - 1 param
//   - body is single ReturnStatement
//   - return value is nested ConditionalExpression
//   - test uses .bridgeConfig and .getSocketPaths
// ============================================================

const funcDecls = findNodes(ast, n => n.type === 'FunctionDeclaration');
const arrowFuncs = findNodes(ast, n => n.type === 'ArrowFunctionExpression');

function isClientFactory(node) {
    // Get body statements
    let bodyStmts;
    if (node.body && node.body.type === 'BlockStatement') {
        bodyStmts = node.body.body;
    } else {
        return false;
    }

    // Must have exactly 1 param
    if (!node.params || node.params.length !== 1) return false;

    // Must have single return statement
    if (bodyStmts.length !== 1 || bodyStmts[0].type !== 'ReturnStatement') return false;

    const ret = bodyStmts[0].argument;
    if (!ret || ret.type !== 'ConditionalExpression') return false;

    // Outer ternary: H.bridgeConfig ? X : Y
    if (ret.test.type !== 'MemberExpression') return false;
    if (ret.test.property.name !== 'bridgeConfig') return false;

    // Inner ternary in alternate: H.getSocketPaths ? X : Y
    const alt = ret.alternate;
    if (!alt || alt.type !== 'ConditionalExpression') return false;
    if (alt.test.type !== 'MemberExpression') return false;
    if (alt.test.property.name !== 'getSocketPaths') return false;

    return true;
}

// Search both function declarations and variable-assigned functions
for (const fn of funcDecls) {
    if (isClientFactory(fn)) {
        fixes.clientFactory.found = true;
        fixes.clientFactory.node = fn;
        console.log('FOUND:clientFactory function ' + fn.id.name + ' -> ' + src(fn).slice(0, 80));
        break;
    }
}

if (!fixes.clientFactory.found) {
    // Also check VariableDeclarators with arrow/function expressions
    const varDecls = findNodes(ast, n => n.type === 'VariableDeclarator');
    for (const decl of varDecls) {
        if (decl.init && (decl.init.type === 'ArrowFunctionExpression' || decl.init.type === 'FunctionExpression')) {
            if (isClientFactory(decl.init)) {
                fixes.clientFactory.found = true;
                fixes.clientFactory.node = decl;
                console.log('FOUND:clientFactory var ' + (decl.id?.name || '?') + ' -> ' + src(decl).slice(0, 80));
                break;
            }
        }
    }
}

// ============================================================
// Find subscription gate: pH = FBH(.chrome) && vA()
// Structural: VariableDeclarator with LogicalExpression(&&)
//   left: CallExpression(arg is MemberExpr .chrome)
//   right: CallExpression(0 args)
// AND near anchor string "tengu_claude_in_chrome_setup"
// ============================================================

if (!code.includes('__ccpp_sub_bypass')) {
    // Structural match: VariableDeclarator where:
    //   init = LogicalExpression(&&)
    //   left = CallExpression(arg is MemberExpression .chrome)
    //   right = CallExpression(0 args)
    //   left callee's function body contains "claudeInChromeDefaultEnabled"
    const varDeclarators = findNodes(ast, n => n.type === 'VariableDeclarator');
    for (const decl of varDeclarators) {
        if (!decl.init || decl.init.type !== 'LogicalExpression' || decl.init.operator !== '&&') continue;
        const left = decl.init.left;
        const right = decl.init.right;
        if (left.type !== 'CallExpression' || !left.arguments?.length) continue;
        const arg = left.arguments[0];
        if (!arg || arg.type !== 'MemberExpression' || arg.property?.name !== 'chrome') continue;
        if (right.type !== 'CallExpression') continue;
        if (right.arguments?.length !== 0) continue;
        // Verify left callee is the chrome config function (contains claudeInChromeDefaultEnabled)
        const calleeName = left.callee?.name || left.callee?.property?.name;
        if (!calleeName) continue;
        const calleeDefs = findNodes(ast, n =>
            (n.type === 'FunctionDeclaration' && n.id?.name === calleeName) ||
            (n.type === 'VariableDeclarator' && n.id?.name === calleeName)
        );
        let verified = false;
        for (const def of calleeDefs) {
            if (src(def).includes('claudeInChromeDefaultEnabled')) { verified = true; break; }
        }
        if (!verified) continue;
        fixes.subscriptionGate.found = true;
        fixes.subscriptionGate.node = decl;
        console.log('FOUND:subscriptionGate ' + decl.id.name + ' -> ' + src(decl).slice(0, 60));
        break;
    }
}

// ============================================================
// Find /chrome subscription message: "Claude in Chrome requires a claude.ai subscription."
// In unpatched code: !f && createElement(...)
// Anchor: the subscription message string itself
// If condition is already "false&&", skip (already patched by CCometixLine)
// ============================================================

if (!code.includes('__ccpp_sub_msg_bypass')) {
    const msgAnchor = 'Claude in Chrome requires a claude.ai subscription.';
    const msgPos = code.indexOf(msgAnchor);
    if (msgPos >= 0) {
        // Check if already patched (false&&)
        const before = code.slice(Math.max(0, msgPos - 200), msgPos);
        if (!before.includes('false&&')) {
            // Find the !f&& or !X&& condition before createElement
            // Pattern: LogicalExpression with !UnaryExpression on left, createElement on right
            // containing our anchor string
            const logicals = findNodes(ast, n => {
                if (n.type !== 'LogicalExpression' || n.operator !== '&&') return false;
                if (n.start > msgPos || n.end < msgPos) return false;
                if (n.left?.type !== 'UnaryExpression' || n.left.operator !== '!') return false;
                return true;
            });
            if (logicals.length > 0) {
                // Get the smallest (most specific) enclosing one
                const target = logicals.reduce((a, b) => (b.end - b.start) < (a.end - a.start) ? b : a);
                fixes.subscriptionMsg.found = true;
                fixes.subscriptionMsg.node = target.left; // the !f part
                console.log('FOUND:subscriptionMsg -> ' + src(target.left));
            }
        }
    }
}

// ============================================================
// Find "Select browser…" menu item
// Structural: ObjectExpression with label:"Select browser…" and value:"select-browser"
// ============================================================

if (!code.includes('__ccpp_no_select_browser')) {
    const selectBrowserNodes = findNodes(ast, n => {
        if (n.type !== 'ObjectExpression') return false;
        const props = n.properties;
        if (!props || props.length < 2) return false;
        return props.some(p => p.key?.name === 'value' && p.value?.value === 'select-browser');
    });
    if (selectBrowserNodes.length > 0) {
        fixes.selectBrowserHide.found = true;
        fixes.selectBrowserHide.node = selectBrowserNodes[0];
        console.log('FOUND:selectBrowserHide -> ' + src(selectBrowserNodes[0]).slice(0, 60));
    }
}

// Check if already patched
const allAlreadyPatched = code.includes('__ccpp_bridge_fallback') &&
    (code.includes('__ccpp_sub_bypass') || !code.includes('tengu_claude_in_chrome_setup')) &&
    (code.includes('__ccpp_no_select_browser') || !code.includes('select-browser'));
if (allAlreadyPatched && !Object.values(fixes).some(f => f.found)) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}
if (!Object.values(fixes).some(f => f.found)) {
    console.error('NOT_FOUND:No patchable patterns found');
    process.exit(1);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = Object.values(fixes).filter(f => f.found).length;
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

// ============================================================
// Apply fix: wrap the factory to add socket fallback
// ============================================================

let newCode = code;
let replacements = [];

if (fixes.clientFactory.found && fixes.clientFactory.node) {
    const node = fixes.clientFactory.node;

    // Get the function body — extract the return statement's conditional
    let fnNode, paramName;
    if (node.type === 'FunctionDeclaration') {
        fnNode = node;
        paramName = node.params[0].name;
    } else {
        // VariableDeclarator
        fnNode = node.init;
        paramName = fnNode.params[0].name;
    }

    const retStmt = fnNode.body.body[0];
    const cond = retStmt.argument;

    // Extract the three factory call names from the ternary
    // cond: H.bridgeConfig ? bridgeFactory(H) : H.getSocketPaths ? socketFactory(H) : nativeFactory(H)
    const bridgeCall = src(cond.consequent);   // ei6(H) or similar
    const socketCall = src(cond.alternate.consequent);  // uFA(H) or similar
    const nativeCall = src(cond.alternate.alternate);   // ri6(H) or similar

    // Extract factory function names
    const bridgeFactoryName = cond.consequent.callee?.name;
    const socketFactoryName = cond.alternate.consequent.callee?.name;

    // New return body: try bridge, wrap with socket fallback
    // The composite client tries bridge first; if ensureConnected fails, delegates to socket
    // Strategy: prefer socket when available, fall back to bridge.
    // Socket client (xFA) is the native path — same API as bridge client,
    // already has ensureConnected/callTool/setNotificationHandler.
    // No proxy needed — just swap the priority.
    const newReturn = `{` +
        `if(${paramName}.getSocketPaths){` +
            `var __paths=${paramName}.getSocketPaths();` +
            `if(__paths&&__paths.length>0)return ${socketCall}` +
        `}` +
        `return ${paramName}.bridgeConfig?${bridgeCall}:${nativeCall}` +
    `}/*__ccpp_bridge_fallback*/`;

    // Replace the function body
    const bodyNode = fnNode.body;
    replacements.push({
        start: bodyNode.start,
        end: bodyNode.end,
        replacement: newReturn,
        name: 'clientFactory'
    });

    fixes.clientFactory.patched = true;
    console.log('PATCH:clientFactory - Socket priority over bridge when local socket available');
}

// ── Subscription gate: remove && vA() ──
if (fixes.subscriptionGate.found && fixes.subscriptionGate.node) {
    const decl = fixes.subscriptionGate.node;
    const right = decl.init.right; // vA() call
    const left = decl.init.left;   // FBH(.chrome) call
    // Replace the whole init (FBH(.chrome) && vA()) with just FBH(.chrome)
    replacements.push({
        start: decl.init.start,
        end: decl.init.end,
        replacement: src(left) + '/*__ccpp_sub_bypass*/',
        name: 'subscriptionGate'
    });
    fixes.subscriptionGate.patched = true;
    console.log('PATCH:subscriptionGate - Removed subscription check for Chrome features');
}

// ── Subscription message: replace !f with false ──
if (fixes.subscriptionMsg.found && fixes.subscriptionMsg.node) {
    const node = fixes.subscriptionMsg.node;
    replacements.push({
        start: node.start,
        end: node.end,
        replacement: 'false/*__ccpp_sub_msg_bypass*/',
        name: 'subscriptionMsg'
    });
    fixes.subscriptionMsg.patched = true;
    console.log('PATCH:subscriptionMsg - Hidden subscription requirement message in /chrome');
}

// ── Hide "Select browser" menu item ──
// Can't remove the if block (breaks React memo cache slots).
// Instead: find the m.push(KH) call inside the if block and replace with empty statement.
if (fixes.selectBrowserHide.found && fixes.selectBrowserHide.node) {
    const sbNode = fixes.selectBrowserHide.node;
    // Find the CallExpression: m.push(KH) that's inside the same if block
    const pushCalls = findNodes(ast, n => {
        if (n.type !== 'CallExpression') return false;
        if (n.callee?.property?.name !== 'push') return false;
        // Must be near and after the select-browser ObjectExpression
        if (n.start < sbNode.start || n.start - sbNode.end > 200) return false;
        return true;
    });
    if (pushCalls.length > 0) {
        // Find the enclosing ExpressionStatement to replace cleanly
        const pushCall = pushCalls[0];
        replacements.push({
            start: pushCall.start,
            end: pushCall.end,
            replacement: 'void 0/*__ccpp_no_select_browser*/',
            name: 'selectBrowserHide'
        });
        fixes.selectBrowserHide.patched = true;
        console.log('PATCH:selectBrowserHide - Disabled Select browser push');
    }
}

// Apply replacements
replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.replacement + newCode.slice(r.end);
}

const patchedCount = Object.values(fixes).filter(f => f.patched).length;
if (patchedCount === 0) {
    console.error('VERIFY_FAILED:No fixes applied');
    process.exit(1);
}

const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
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
            success "Already patched"
            exit 0
            ;;
        PARSE_ERROR:*)
            error "Failed to parse cli.js: ${line#PARSE_ERROR:}"
            exit 1
            ;;
        NOT_FOUND:*)
            error "Target not found: ${line#NOT_FOUND:}"
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
            success "Fix applied! Patched ${line#SUCCESS:} location(s)"
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
