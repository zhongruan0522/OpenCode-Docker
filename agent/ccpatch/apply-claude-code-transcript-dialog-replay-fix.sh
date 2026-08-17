#!/bin/bash
#
# Claude Code Transcript Permission Dialog Replay Fix Script
#
# Fixes: Permission dialogs can be lost when a tool asks for approval while the
#        user is viewing the Ctrl+O transcript detail screen.
#
# THE BUG:
# In Claude Code 2.1.143+ / 2.1.144+ dialog prompts are delivered through a
# transient requestDialog channel. The main prompt screen mounts the dialog host,
# but the transcript screen does not. If a Bash/Edit/etc permission request is
# emitted while Ctrl+O transcript is active, there is no subscriber, the event is
# dropped, and the tool remains stuck at "Waiting…" even after returning to the
# main prompt.
#
# ROOT CAUSE:
# The dialog channel stores only reply callbacks. It does not keep/replay pending
# dialog requests for a dialog host that subscribes later. Older Claude Code used
# a React state queue for tool confirmations, which naturally survived screen
# switches; the new request/response channel lost that persistence.
#
# FIX:
# 1) Patch the dialog channel factory so pending dialog requests are stored with
#    their payload and replayed to newly mounted dialog hosts. Payload updates are
#    also retained, and abort/cancel semantics are preserved.
# 2) Patch the dialog host cleanup so screen-switch unmount only dismisses the
#    current UI instance and does not reply `{ cancelled: true }`. Real user
#    cancellation and request abort still cancel normally.
#
# Usage:
#   ./apply-claude-code-transcript-dialog-replay-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-transcript-dialog-replay-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-transcript-dialog-replay-fix.sh --check            # Check only
#   ./apply-claude-code-transcript-dialog-replay-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-transcript-dialog-replay"
FIX_DESCRIPTION="Fix lost permission dialogs after Ctrl+O transcript view by replaying pending dialog requests"

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
        "$HOME/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
        "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        "$HOME/.claude/local/node_modules/@cometix/claude-code/cli.js"
        "/usr/local/lib/node_modules/@cometix/claude-code/cli.js"
        "/usr/lib/node_modules/@cometix/claude-code/cli.js"
    )
    if command -v npm &> /dev/null; then
        local npm_root
        npm_root=$(npm root -g 2>/dev/null || true)
        if [[ -n "$npm_root" ]]; then
            locations+=("$npm_root/@anthropic-ai/claude-code/cli.js")
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
        echo "  ~/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
        echo "  /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        echo "  /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        echo "  ~/.claude/local/node_modules/@cometix/claude-code/cli.js"
        echo "  /usr/local/lib/node_modules/@cometix/claude-code/cli.js"
        echo "  /usr/lib/node_modules/@cometix/claude-code/cli.js"
        echo "  \$(npm root -g)/@anthropic-ai/claude-code/cli.js"
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
# Node.js patch script (AST-based)
# ============================================================
PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');
const acornPath = process.argv[2];
const acorn = require(acornPath);

const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup-transcript-dialog-replay';

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
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'script' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        const value = node[key];
        if (!value || typeof value !== 'object') continue;
        if (Array.isArray(value)) {
            for (const child of value) findNodes(child, predicate, results);
        } else {
            findNodes(value, predicate, results);
        }
    }
    return results;
}

function propName(prop) {
    if (!prop || !prop.key) return undefined;
    if (prop.key.type === 'Identifier') return prop.key.name;
    if (prop.key.type === 'Literal') return String(prop.key.value);
    return undefined;
}

function isIdentifier(node, name) {
    return node && node.type === 'Identifier' && node.name === name;
}

function isSubscribeMember(node, objName) {
    return node && node.type === 'MemberExpression' &&
        isIdentifier(node.object, objName) &&
        !node.computed &&
        node.property && node.property.type === 'Identifier' &&
        node.property.name === 'subscribe';
}

function findDeferredFactoryName(requestFn) {
    const calls = findNodes(requestFn, n =>
        n.type === 'VariableDeclarator' &&
        n.id && n.id.type === 'ObjectPattern' &&
        n.init && n.init.type === 'CallExpression' &&
        n.init.callee &&
        (n.init.callee.type === 'Identifier' || n.init.callee.type === 'MemberExpression') &&
        n.id.properties.some(p => propName(p) === 'promise') &&
        n.id.properties.some(p => propName(p) === 'resolve')
    );
    if (!calls[0]) return null;
    const callee = calls[0].init.callee;
    if (callee.type === 'Identifier') return callee.name;
    return code.slice(callee.start, callee.end);
}

function analyzeDialogChannelFactory(fn) {
    if (!fn.body || fn.body.type !== 'BlockStatement') return null;
    if (fn.params && fn.params.length !== 0) return null;
    // Safety guard for whole-body replacement: only patch the tiny dialog
    // channel factory shape used by affected versions. Refuse future variants
    // that add setup/cleanup/telemetry statements instead of dropping them.
    if (fn.body.body.length !== 2) return null;
    if (fn.body.body[0].type !== 'VariableDeclaration') return null;
    if (fn.body.body[1].type !== 'ReturnStatement') return null;

    const firstDecl = fn.body.body.find(stmt =>
        stmt.type === 'VariableDeclaration' &&
        stmt.declarations && stmt.declarations.length >= 5 &&
        stmt.declarations[0].id.type === 'Identifier' &&
        stmt.declarations[1].id.type === 'Identifier' &&
        stmt.declarations[2].id.type === 'Identifier' &&
        stmt.declarations[3].id.type === 'Identifier' &&
        stmt.declarations[4].id.type === 'Identifier' &&
        stmt.declarations[0].init?.type === 'CallExpression' &&
        stmt.declarations[1].init?.type === 'CallExpression' &&
        stmt.declarations[2].init?.type === 'CallExpression' &&
        stmt.declarations[3].init?.type === 'NewExpression' &&
        stmt.declarations[3].init.callee?.type === 'Identifier' &&
        stmt.declarations[3].init.callee.name === 'Map' &&
        stmt.declarations[4].init?.type === 'Literal' &&
        stmt.declarations[4].init.value === 0
    );
    if (!firstDecl) return null;

    const eventSignal = firstDecl.declarations[0].id.name;
    const cancelSignal = firstDecl.declarations[1].id.name;
    const updateSignal = firstDecl.declarations[2].id.name;
    const pendingMap = firstDecl.declarations[3].id.name;
    const counter = firstDecl.declarations[4].id.name;
    const eventSignalFactorySrc = code.slice(firstDecl.declarations[0].init.start, firstDecl.declarations[0].init.end);
    const cancelSignalFactorySrc = code.slice(firstDecl.declarations[1].init.start, firstDecl.declarations[1].init.end);
    const updateSignalFactorySrc = code.slice(firstDecl.declarations[2].init.start, firstDecl.declarations[2].init.end);

    const ret = fn.body.body.find(stmt => stmt.type === 'ReturnStatement' && stmt.argument?.type === 'ObjectExpression');
    if (!ret) return null;

    const propNames = ret.argument.properties.map(propName);
    const expectedPropNames = ['subscribe', 'onCancel', 'onUpdate', 'reply', 'request'];
    if (propNames.length !== expectedPropNames.length) return null;
    if (!expectedPropNames.every(name => propNames.includes(name))) return null;

    const props = new Map(ret.argument.properties.map(p => [propName(p), p]));
    const subscribeProp = props.get('subscribe');
    const onCancelProp = props.get('onCancel');
    const onUpdateProp = props.get('onUpdate');
    const replyProp = props.get('reply');
    const requestProp = props.get('request');
    if (!subscribeProp || !onCancelProp || !onUpdateProp || !replyProp || !requestProp) return null;
    if (!isSubscribeMember(onCancelProp.value, cancelSignal)) return null;
    if (!isSubscribeMember(onUpdateProp.value, updateSignal)) return null;

    const requestFn = requestProp.value;
    if (!requestFn || (requestFn.type !== 'FunctionExpression' && requestFn.type !== 'ArrowFunctionExpression')) return null;
    const deferredFactory = findDeferredFactoryName(requestFn);
    if (!deferredFactory) return null;

    const subscribeIsOld = isSubscribeMember(subscribeProp.value, eventSignal);
    const subscribeSrc = code.slice(subscribeProp.start, subscribeProp.end);
    const alreadyPatched = !subscribeIsOld &&
        subscribeSrc.includes('.values()') &&
        subscribeSrc.includes('queueMicrotask') &&
        code.slice(fn.body.start, fn.body.end).includes('event:');

    if (!subscribeIsOld && !alreadyPatched) return null;

    return {
        fn,
        eventSignal,
        cancelSignal,
        updateSignal,
        pendingMap,
        counter,
        eventSignalFactorySrc,
        cancelSignalFactorySrc,
        updateSignalFactorySrc,
        deferredFactory,
        subscribeIsOld,
        alreadyPatched
    };
}

function memberPropName(node) {
    if (!node || node.type !== 'MemberExpression') return undefined;
    if (!node.computed && node.property?.type === 'Identifier') return node.property.name;
    if (node.computed && node.property?.type === 'Literal') return String(node.property.value);
    return undefined;
}

function objectHasTrueProp(obj, name) {
    return obj && obj.type === 'ObjectExpression' && obj.properties.some(p =>
        propName(p) === name &&
        ((p.value?.type === 'Literal' && p.value.value === true) ||
         (p.value?.type === 'UnaryExpression' && p.value.operator === '!' && p.value.argument?.type === 'Literal' && p.value.argument.value === 0))
    );
}

function objectHasIdPropForVar(obj, name) {
    return obj && obj.type === 'ObjectExpression' && obj.properties.some(p =>
        propName(p) === 'id' && isIdentifier(p.value, name)
    );
}

function callsMemberProp(node, prop) {
    return findNodes(node, n =>
        n.type === 'CallExpression' &&
        n.callee?.type === 'MemberExpression' &&
        memberPropName(n.callee) === prop
    ).length > 0;
}

function statementExpressions(stmt) {
    if (!stmt) return [];
    if (stmt.type === 'ExpressionStatement') {
        if (stmt.expression.type === 'SequenceExpression') return stmt.expression.expressions;
        return [stmt.expression];
    }
    if (stmt.type === 'BlockStatement' && stmt.body.length === 1) return statementExpressions(stmt.body[0]);
    return [];
}

function isDismissCall(expr, loopVar) {
    return expr?.type === 'CallExpression' &&
        expr.callee?.type === 'MemberExpression' &&
        memberPropName(expr.callee) === 'dismiss' &&
        expr.arguments.length === 1 &&
        isIdentifier(expr.arguments[0], loopVar);
}

function isCancelledReplyCall(expr, loopVar) {
    if (expr?.type !== 'CallExpression') return false;
    if (expr.callee?.type !== 'MemberExpression') return false;
    if (memberPropName(expr.callee) !== 'reply') return false;
    const arg = expr.arguments[0];
    return objectHasTrueProp(arg, 'cancelled') && objectHasIdPropForVar(arg, loopVar);
}

function analyzeDialogHostCleanup(fn) {
    if (!fn.body || fn.body.type !== 'BlockStatement') return null;
    // The dialog host hook function has both an Ig.onClosed(...) subscription
    // and a React useEffect(...) that installs channel subscriptions.
    if (!callsMemberProp(fn, 'onClosed') || !callsMemberProp(fn, 'useEffect')) return null;

    let oldLoops = [];
    let patchedLoops = [];
    const loops = findNodes(fn, n => n.type === 'ForOfStatement');
    for (const loop of loops) {
        const decl = loop.left?.type === 'VariableDeclaration' ? loop.left.declarations?.[0] : null;
        const loopVar = decl?.id?.type === 'Identifier' ? decl.id.name : null;
        if (!loopVar) continue;
        const exprs = statementExpressions(loop.body);
        const dismiss = exprs.find(e => isDismissCall(e, loopVar));
        if (!dismiss) continue;
        const cancelledReply = exprs.find(e => isCancelledReplyCall(e, loopVar));
        if (cancelledReply) {
            oldLoops.push({ loop, loopVar, dismiss });
        } else if (exprs.length === 1) {
            patchedLoops.push({ loop, loopVar, dismiss });
        }
    }

    if (oldLoops.length > 1) {
        return { ambiguous: true, count: oldLoops.length };
    }
    if (oldLoops.length === 1) {
        return { fn, old: true, alreadyPatched: false, ...oldLoops[0] };
    }
    if (patchedLoops.length > 0) {
        return { fn, old: false, alreadyPatched: true, ...patchedLoops[0] };
    }
    return null;
}

const functions = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression'
);

// Fix point 1: requestDialog channel must replay pending requests to later hosts.
const factoryCandidates = functions.map(analyzeDialogChannelFactory).filter(Boolean);
const factoryTargets = factoryCandidates.filter(c => c.subscribeIsOld);
const factoryAlreadyPatched = factoryCandidates.some(c => c.alreadyPatched);
if (factoryTargets.length > 1) {
    console.error('NOT_FOUND:Found multiple dialog channel factory candidates; refusing ambiguous patch (' + factoryTargets.length + ')');
    process.exit(1);
}

// Fix point 2: dialog host unmount (screen switch) must not answer cancelled.
const cleanupCandidates = functions.map(analyzeDialogHostCleanup).filter(Boolean);
const ambiguousCleanup = cleanupCandidates.find(c => c.ambiguous);
if (ambiguousCleanup) {
    console.error('NOT_FOUND:Found multiple dialog cleanup loops in one host; refusing ambiguous patch (' + ambiguousCleanup.count + ')');
    process.exit(1);
}
const cleanupTargets = cleanupCandidates.filter(c => c.old);
const cleanupAlreadyPatched = cleanupCandidates.some(c => c.alreadyPatched);
if (cleanupTargets.length > 1) {
    console.error('NOT_FOUND:Found multiple dialog host cleanup candidates; refusing ambiguous patch (' + cleanupTargets.length + ')');
    process.exit(1);
}

if (factoryTargets.length === 0 && !factoryAlreadyPatched) {
    console.error('NOT_FOUND:Unable to locate old dialog channel factory (subscribe:<signal>.subscribe, pending Map, reply/request methods)');
    process.exit(1);
}
if (cleanupTargets.length === 0 && !cleanupAlreadyPatched) {
    console.error('NOT_FOUND:Unable to locate old dialog host cleanup cancellation loop');
    process.exit(1);
}

let replacements = [];

if (factoryTargets.length === 1) {
    const t = factoryTargets[0];
    const name = t.fn.id?.name || '<anonymous>';
    console.log('FOUND:dialog channel factory ' + name + ' at byte ' + t.fn.start);

    const H = t.eventSignal;
    const C = t.cancelSignal;
    const U = t.updateSignal;
    const Q = t.pendingMap;
    const K = t.counter;
    const eventSignalFactory = t.eventSignalFactorySrc;
    const cancelSignalFactory = t.cancelSignalFactorySrc;
    const updateSignalFactory = t.updateSignalFactorySrc;
    const deferredFactory = t.deferredFactory;

    const replacementBody = `{let ${H}=${eventSignalFactory},${C}=${cancelSignalFactory},${U}=${updateSignalFactory},${Q}=new Map,${K}=0;return{subscribe(CC_DIALOG_FIX_listener){let CC_DIALOG_FIX_unsub=${H}.subscribe(CC_DIALOG_FIX_listener);for(let CC_DIALOG_FIX_entry of ${Q}.values())queueMicrotask(()=>{if(${Q}.has(CC_DIALOG_FIX_entry.id))CC_DIALOG_FIX_listener(CC_DIALOG_FIX_entry.event)});return CC_DIALOG_FIX_unsub},onCancel:${C}.subscribe,onUpdate:${U}.subscribe,reply(CC_DIALOG_FIX_reply){let CC_DIALOG_FIX_entry=${Q}.get(CC_DIALOG_FIX_reply.id);if(!CC_DIALOG_FIX_entry)return;${Q}.delete(CC_DIALOG_FIX_reply.id),CC_DIALOG_FIX_entry.resolve(CC_DIALOG_FIX_reply)},request({kind:CC_DIALOG_FIX_kind,payload:CC_DIALOG_FIX_payload},CC_DIALOG_FIX_options){${K}+=1;let CC_DIALOG_FIX_id=\`dialog-\${${K}}\`,{promise:CC_DIALOG_FIX_promise,resolve:CC_DIALOG_FIX_resolve}=${deferredFactory}(),CC_DIALOG_FIX_signal=CC_DIALOG_FIX_options?.signal;if(CC_DIALOG_FIX_signal?.aborted)return queueMicrotask(()=>CC_DIALOG_FIX_resolve({id:CC_DIALOG_FIX_id,cancelled:!0})),{id:CC_DIALOG_FIX_id,replied:CC_DIALOG_FIX_promise,update:()=>{}};let CC_DIALOG_FIX_abort,CC_DIALOG_FIX_event={id:CC_DIALOG_FIX_id,kind:CC_DIALOG_FIX_kind,payload:CC_DIALOG_FIX_payload};if(${Q}.set(CC_DIALOG_FIX_id,{id:CC_DIALOG_FIX_id,event:CC_DIALOG_FIX_event,resolve:(CC_DIALOG_FIX_value)=>{if(CC_DIALOG_FIX_signal&&CC_DIALOG_FIX_abort)CC_DIALOG_FIX_signal.removeEventListener("abort",CC_DIALOG_FIX_abort);CC_DIALOG_FIX_resolve(CC_DIALOG_FIX_value)}}),CC_DIALOG_FIX_signal)CC_DIALOG_FIX_abort=()=>{if(${Q}.delete(CC_DIALOG_FIX_id))CC_DIALOG_FIX_resolve({id:CC_DIALOG_FIX_id,cancelled:!0}),${C}.emit(CC_DIALOG_FIX_id)},CC_DIALOG_FIX_signal.addEventListener("abort",CC_DIALOG_FIX_abort,{once:!0});return ${H}.emit(CC_DIALOG_FIX_event),{id:CC_DIALOG_FIX_id,replied:CC_DIALOG_FIX_promise,update:(CC_DIALOG_FIX_payload_update)=>{let CC_DIALOG_FIX_entry=${Q}.get(CC_DIALOG_FIX_id);if(CC_DIALOG_FIX_entry){CC_DIALOG_FIX_entry.event={...CC_DIALOG_FIX_entry.event,payload:CC_DIALOG_FIX_payload_update};${U}.emit({id:CC_DIALOG_FIX_id,payload:CC_DIALOG_FIX_payload_update})}}}}}}`;

    replacements.push({
        start: t.fn.body.start,
        end: t.fn.body.end,
        replacement: replacementBody,
        name: 'dialog-channel-replay'
    });
} else {
    console.log('FOUND:dialog channel factory already has pending replay');
}

if (cleanupTargets.length === 1) {
    const t = cleanupTargets[0];
    const name = t.fn.id?.name || '<anonymous>';
    const dismissSrc = code.slice(t.dismiss.start, t.dismiss.end);
    console.log('FOUND:dialog host cleanup ' + name + ' at byte ' + t.loop.start);
    replacements.push({
        start: t.loop.body.start,
        end: t.loop.body.end,
        replacement: dismissSrc + ';',
        name: 'dialog-host-nondestructive-cleanup'
    });
} else {
    console.log('FOUND:dialog host cleanup already avoids cancellation on unmount');
}

if (replacements.length === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + replacements.length);
    process.exit(1);
}

let newCode = code;
replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.replacement + newCode.slice(r.end);
    console.log('PATCH:' + r.name);
}

try {
    acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'script' });
} catch (e) {
    console.error('VERIFY_FAILED:Patched cli.js failed to parse: ' + e.message);
    process.exit(1);
}

if (replacements.some(r => r.name === 'dialog-channel-replay') &&
    (!newCode.includes('CC_DIALOG_FIX_listener') || !newCode.includes('CC_DIALOG_FIX_entry.event'))) {
    console.error('VERIFY_FAILED:Dialog replay patch markers missing after rewrite');
    process.exit(1);
}
if (replacements.some(r => r.name === 'dialog-host-nondestructive-cleanup') &&
    /for\s*\([^)]*\)\s*[^;{}]*\.dismiss\([^)]*\)\s*,\s*[^;{}]*\.reply\(\{[^}]*cancelled/.test(newCode)) {
    console.error('VERIFY_FAILED:Old destructive cleanup pattern still appears after rewrite');
    process.exit(1);
}

const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + replacements.length);
PATCH_EOF

# ============================================================
# Execute patch script
# ============================================================
CHECK_ARG=""
if $CHECK_ONLY; then
    CHECK_ARG="--check"
fi

set +e
OUTPUT=$(node "$PATCH_SCRIPT" "$ACORN_PATH" "$CLI_PATH" "$CHECK_ARG" 2>&1)
EXIT_CODE=$?
set -e

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
        *)
            if [[ -n "$line" ]]; then
                echo "$line"
            fi
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
