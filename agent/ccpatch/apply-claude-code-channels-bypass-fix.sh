#!/bin/bash
#
# Claude Code Channels Decision Bypass Fix Script
#
# THE FEATURE:
# --channels registers MCP server channel notifications (inbound push).
# The qMq() decision function has 7 layers of checks before allowing
# a channel to register.
#
# FIX:
# Bypass checks 2-7 (feature flag, auth, policy, session whitelist,
# marketplace, allowlist) while preserving check 1 (MCP capability
# declaration) which is a legitimate protocol requirement.
#
# After patching, any MCP server declaring claude/channel capability
# will be registered regardless of auth, feature flags, or allowlists.
#
# Usage:
#   ./apply-claude-code-channels-bypass-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-channels-bypass-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-channels-bypass-fix.sh --check            # Check only
#   ./apply-claude-code-channels-bypass-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-channels-bypass"
FIX_DESCRIPTION="Bypass channel decision checks 2-7 (keep MCP capability check)"

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
// Find qMq() — the channel decision function
//
// Identification: FunctionDeclaration containing Literal
// "server did not declare claude/channel capability"
// and Literal "channels feature is not currently available"
//
// Strategy: preserve the first if-block (capability check),
// remove checks 2-7, keep the final return {action:"register"}
// ============================================================

// ============================================================
// Patch 1: Force-enable tengu_harbor feature flag
//   Ra6(){return A1("tengu_harbor",!1)} → change !1 to !0
//   This also fixes the ChannelsNotice UI (Kq_() uses Ra6())
// ============================================================

const harborCalls = findNodes(ast, n =>
    n.type === 'CallExpression' &&
    n.arguments &&
    n.arguments.length === 2 &&
    n.arguments[0].type === 'Literal' &&
    n.arguments[0].value === 'tengu_harbor' &&
    !(n.arguments[0].value === 'tengu_harbor_ledger')
);

let harborPatched = false;
let harborCalleeName = '';

for (const call of harborCalls) {
    harborCalleeName = src(call.callee);
    const secondArg = call.arguments[1];
    if (secondArg.type === 'UnaryExpression' &&
        secondArg.operator === '!' &&
        secondArg.argument.type === 'Literal' &&
        secondArg.argument.value === 1) {
        console.log('FOUND:harborFlag ' + harborCalleeName + '("tengu_harbor", !1)');
        break;
    }
    if (secondArg.type === 'UnaryExpression' &&
        secondArg.operator === '!' &&
        secondArg.argument.type === 'Literal' &&
        secondArg.argument.value === 0) {
        console.log('FOUND:harborFlag already enabled');
        harborPatched = true;
        break;
    }
}

// ============================================================
// Patch 2: Bypass qMq() decision checks 2-7
// ============================================================

// Find the marker string — unique to qMq()
const markerLiterals = findNodes(ast, n =>
    n.type === 'Literal' &&
    n.value === 'channels feature is not currently available'
);

if (markerLiterals.length === 0) {
    if (code.includes('claude/channel capability') &&
        !code.includes('channels feature is not currently available')) {
        if (harborPatched) {
            console.log('ALREADY_PATCHED');
            process.exit(2);
        }
        // qMq already patched but harbor flag not yet — continue to patch harbor
    } else {
        console.error('NOT_FOUND:Cannot find channel decision function marker');
        process.exit(1);
    }
}

// Find enclosing function
const markerPos = markerLiterals[0].start;
const enclosingFuncs = findNodes(ast, n =>
    (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression') &&
    n.start < markerPos && n.end > markerPos
);

if (enclosingFuncs.length === 0) {
    console.error('NOT_FOUND:Cannot find enclosing function for channel decision');
    process.exit(1);
}

const targetFunc = enclosingFuncs.sort((a, b) => (a.end - a.start) - (b.end - b.start))[0];
const funcName = targetFunc.id ? targetFunc.id.name : '(anonymous)';

console.log('FOUND:channelDecision function ' + funcName + '() at ' + targetFunc.start + '-' + targetFunc.end);
console.log('FOUND:bodySize ' + (targetFunc.body.end - targetFunc.body.start) + ' bytes');

// Extract the capability check — the first if-statement in the function body
// It checks: if (!q?.experimental?.["claude/channel"]) return {action:"skip",...}
const bodyStatements = targetFunc.body.body;
if (!bodyStatements || bodyStatements.length === 0) {
    console.error('NOT_FOUND:Function body has no statements');
    process.exit(1);
}

const firstStmt = bodyStatements[0];
if (firstStmt.type !== 'IfStatement') {
    console.error('NOT_FOUND:First statement is not an if-check, got: ' + firstStmt.type);
    process.exit(1);
}

// Verify the first if contains "claude/channel"
const firstStmtSrc = src(firstStmt);
if (!firstStmtSrc.includes('claude/channel')) {
    console.error('NOT_FOUND:First if-statement does not contain claude/channel check');
    process.exit(1);
}

console.log('FOUND:capabilityCheck preserved (' + (firstStmt.end - firstStmt.start) + ' bytes)');

// Count bypassed checks
const skipReturns = findNodes(targetFunc, n =>
    n.type === 'ReturnStatement' &&
    n.argument && n.argument.type === 'ObjectExpression'
);
const skipCount = skipReturns.filter(n => {
    const s = src(n);
    return s.includes('"skip"') && n.start > firstStmt.end;
}).length;
console.log('FOUND:bypassedChecks ' + skipCount + ' skip-return statements will be removed');

// ============================================================
// Patch 3: Neutralize Kq_() UI status — always return all-green
//   Find function returning object with policyBlocked + disabled + noAuth
//   Replace body so it always returns disabled:false, noAuth:false, policyBlocked:false
// ============================================================

// Find Property node with key "policyBlocked" — unique to Kq_()
const policyProps = findNodes(ast, n =>
    n.type === 'Property' &&
    n.key && n.key.type === 'Identifier' && n.key.name === 'policyBlocked' &&
    n.value && src(n.value).includes('channelsEnabled')
);

let noticeFunc = null;
let noticePatched = false;

if (policyProps.length > 0) {
    const propPos = policyProps[0].start;
    const noticeFuncs = findNodes(ast, n =>
        (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression') &&
        n.start < propPos && n.end > propPos
    );
    if (noticeFuncs.length > 0) {
        noticeFunc = noticeFuncs.sort((a, b) => (a.end - a.start) - (b.end - b.start))[0];
        const nfName = noticeFunc.id ? noticeFunc.id.name : '(anonymous)';
        console.log('FOUND:channelNotice function ' + nfName + '() — UI status will be neutralized');
    }
} else {
    // Check if already patched — no policyBlocked with channelsEnabled check
    if (code.includes('policyBlocked') && !code.includes('channelsEnabled!==!0')) {
        noticePatched = true;
        console.log('FOUND:channelNotice already neutralized');
    }
}

// Check if anything needs patching
const qMqNeedsPatch = markerLiterals.length > 0;
const harborNeedsPatch = harborCalls.length > 0 && !harborPatched;
const noticeNeedsPatch = noticeFunc !== null && !noticePatched;

if (!qMqNeedsPatch && !harborNeedsPatch && !noticeNeedsPatch) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = (qMqNeedsPatch ? 1 : 0) + (harborNeedsPatch ? 1 : 0) + (noticeNeedsPatch ? 1 : 0);
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

// ============================================================
// Build replacement body:
//   {
//     <original capability check>
//     return{action:"register"}
//   }
// ============================================================

// Collect replacements (apply from end to start to preserve positions)
let replacements = [];
let patchCount = 0;

// Patch 2: qMq() body replacement
if (qMqNeedsPatch) {
    const capCheckSrc = src(firstStmt);
    const newBody = '{' + capCheckSrc + 'return{action:"register"}}';
    replacements.push({
        start: targetFunc.body.start,
        end: targetFunc.body.end,
        replacement: newBody,
        name: 'qMq'
    });
    patchCount++;
    console.log('PATCH:channelDecision - Bypassed checks 2-7, kept MCP capability check');
}

// Patch 1: tengu_harbor flag
if (harborNeedsPatch) {
    const harborArg = harborCalls[0].arguments[1];
    replacements.push({
        start: harborArg.start,
        end: harborArg.end,
        replacement: '!0',
        name: 'harborFlag'
    });
    patchCount++;
    console.log('PATCH:harborFlag - Changed tengu_harbor default from !1 to !0');
}

// Patch 3: Kq_() UI status — always all-green
if (noticeNeedsPatch && noticeFunc) {
    // Dynamically extract function/variable names from original body:
    //   - The allowedChannels getter: Ju() → first CallExpression in body
    //   - The formatter: qo6 → argument of .map() call

    // Find the first call in the function (= Ju() equivalent)
    const firstCalls = findNodes(noticeFunc.body.body[0], n =>
        n.type === 'CallExpression' &&
        n.callee && n.callee.type === 'Identifier'
    );
    const getAllowedChannels = firstCalls.length > 0 ? src(firstCalls[0]) : 'Ju()';

    // Find .map(formatter) call
    const mapCalls = findNodes(noticeFunc, n =>
        n.type === 'CallExpression' &&
        n.callee && n.callee.type === 'MemberExpression' &&
        n.callee.property && n.callee.property.name === 'map'
    );
    let formatter = 'qo6';
    if (mapCalls.length > 0 && mapCalls[0].arguments[0]) {
        formatter = src(mapCalls[0].arguments[0]);
    }

    console.log('FOUND:channelNotice getAllowedChannels=' + getAllowedChannels + ' formatter=' + formatter);

    const newNoticeBody = '{let A=' + getAllowedChannels + ';let q=A.length>0?A.map(' + formatter + ').join(", "):"";return{channels:A,disabled:!1,noAuth:!1,policyBlocked:!1,list:q}}';
    replacements.push({
        start: noticeFunc.body.start,
        end: noticeFunc.body.end,
        replacement: newNoticeBody,
        name: 'channelNotice'
    });
    patchCount++;
    console.log('PATCH:channelNotice - Neutralized UI status (always all-green)');
}

// Apply from end to start
replacements.sort((a, b) => b.start - a.start);
let newCode = code;
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.replacement + newCode.slice(r.end);
}

// Verify
if (qMqNeedsPatch) {
    if (!newCode.includes('claude/channel capability')) {
        console.error('VERIFY_FAILED:Capability check not preserved');
        process.exit(1);
    }
    if (newCode.includes('channels feature is not currently available')) {
        console.error('VERIFY_FAILED:Feature flag check was not removed');
        process.exit(1);
    }
}

if (harborNeedsPatch) {
    const expected = harborCalleeName + '("tengu_harbor",!0)';
    if (!newCode.includes(expected)) {
        console.error('VERIFY_FAILED:Expected "' + expected + '" not found after harbor flag patch');
        process.exit(1);
    }
}

// Backup and save
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchCount);
PATCH_EOF

# ============================================================
# Execute
# ============================================================
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
            info "Channel checks bypassed: auth, feature flag, policy, session, marketplace, allowlist"
            info "Preserved: MCP capability declaration check (claude/channel)"
            ;;
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
