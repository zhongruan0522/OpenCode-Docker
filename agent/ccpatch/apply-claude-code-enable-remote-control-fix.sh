#!/bin/bash
#
# Claude Code Enable Remote Control Fix Script
#
# PURPOSE:
# Unlocks Remote Control for accounts/environments where it's gated.
# Does NOT redirect URLs or override auth tokens — connects to claude.ai.
#
# PATCHES:
#
# PATCH A — Feature flag bypass (tengu_ccr_bridge)
#   Patches ALL isBridgeEnabled functions (sync + async) to return true.
#   Handles both single-return CallExpression/LogicalExpression (old/new)
#   and multi-statement async functions with early return injection.
#
# PATCH B — Organization policy bypass (allow_remote_sessions / allow_remote_control)
#   Injects early return in the policy check function, bypassing org restrictions.
#
# PATCH C — Preflight bypass (S1K / getBridgeDisabledReason)
#   When GrowthBook/nonessential-traffic is disabled, RC preflight hangs.
#   Bypasses both the REPL preflight (S1K) and the disabled-reason check (QG8).
#
# DETECTION: AST-based, version-agnostic string anchors.
# Verified: v2.1.55, v2.1.71, v2.1.162
#
# Usage:
#   ./apply-claude-code-enable-remote-control-fix.sh                    # Apply
#   ./apply-claude-code-enable-remote-control-fix.sh /path/to/cli.js    # Specific file
#   ./apply-claude-code-enable-remote-control-fix.sh --check            # Dry run
#   ./apply-claude-code-enable-remote-control-fix.sh --restore          # Revert

set -e

BACKUP_SUFFIX="backup-remote-ctrl"
FIX_DESCRIPTION="Enable Remote Control (feature flag + policy + preflight bypass)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[X]${NC} $1"; }
info()    { echo -e "${BLUE}[>]${NC} $1"; }

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
            echo "  --check, -c    Dry run"
            echo "  --restore, -r  Revert from backup"
            echo "  --help, -h     Help"
            echo ""
            echo "After patching:"
            echo "  claude remote-control"
            exit 0
            ;;
        -*) error "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "$CLI_PATH_ARG" ]]; then CLI_PATH_ARG="$1"
            else error "Unexpected argument: $1"; exit 1; fi
            shift ;;
    esac
done

find_cli_path() {
    local locations=(
        "$HOME/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
        "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    )
    if command -v npm &> /dev/null; then
        local npm_root
        npm_root=$(npm root -g 2>/dev/null || true)
        [[ -n "$npm_root" ]] && locations+=("$npm_root/@anthropic-ai/claude-code/cli.js")
    fi
    for path in "${locations[@]}"; do
        [[ -f "$path" ]] && echo "$path" && return 0
    done
    return 1
}

if [[ -n "$CLI_PATH_ARG" ]]; then
    [[ -f "$CLI_PATH_ARG" ]] || { error "File not found: $CLI_PATH_ARG"; exit 1; }
    CLI_PATH="$CLI_PATH_ARG"
    info "Using: $CLI_PATH"
else
    CLI_PATH=$(find_cli_path) || { error "cli.js not found. Specify path: $0 /path/to/cli.js"; exit 1; }
    info "Found: $CLI_PATH"
fi

CLI_DIR=$(dirname "$CLI_PATH")

if $RESTORE; then
    LATEST_BACKUP=$(ls -t "$CLI_DIR"/cli.js.${BACKUP_SUFFIX}-* 2>/dev/null | head -1)
    [[ -n "$LATEST_BACKUP" ]] && { cp "$LATEST_BACKUP" "$CLI_PATH"; success "Restored: $LATEST_BACKUP"; exit 0; }
    error "No backup found"; exit 1
fi

echo ""

ACORN_PATH="/tmp/acorn-claude-fix.js"
[[ -f "$ACORN_PATH" ]] || {
    info "Downloading acorn parser..."
    curl -sL "https://unpkg.com/acorn@8.16.0/dist/acorn.js" -o "$ACORN_PATH" || { error "Failed to download acorn"; exit 1; }
}

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

const versionMatch = code.match(/VERSION:\s*"(\d+\.\d+\.\d+)"/);
console.log('VERSION:' + (versionMatch ? versionMatch[1] : 'unknown'));

const markers = { A: '/*RCFF*/', B: '/*RCPB*/', C: '/*RCPF*/' };
const has = {};
for (const [k, v] of Object.entries(markers)) has[k] = code.includes(v);

if (Object.values(has).every(Boolean)) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

function findNodes(node, pred, res = []) {
    if (!node || typeof node !== 'object') return res;
    if (pred(node)) res.push(node);
    for (const k in node) {
        if (k === 'start' || k === 'end' || k === 'type') continue;
        if (node[k] && typeof node[k] === 'object') {
            if (Array.isArray(node[k])) node[k].forEach(c => findNodes(c, pred, res));
            else findNodes(node[k], pred, res);
        }
    }
    return res;
}

const src = n => code.slice(n.start, n.end);
const allFuncDecls = findNodes(ast, n => n.type === 'FunctionDeclaration');

function isReturnTrue(arg) {
    if (!arg) return false;
    if (arg.type === 'Literal' && arg.value === true) return true;
    if (arg.type === 'UnaryExpression' && arg.operator === '!' &&
        arg.argument.type === 'Literal' && (arg.argument.value === 0 || arg.argument.value === false)) return true;
    return false;
}

let patches = [];
let patchCount = 0;

// ═════════════════════════════════════════════════════════════
// PATCH A: Feature flag bypass (tengu_ccr_bridge)
// Handles sync (single-return) and async (multi-statement) variants.
// ═════════════════════════════════════════════════════════════
if (!has.A) {
    console.log('STEP:A - Feature flag bypass');

    const flagLits = findNodes(ast, n => n.type === 'Literal' && n.value === 'tengu_ccr_bridge');
    if (flagLits.length === 0) { console.error('NOT_FOUND:No "tengu_ccr_bridge" — this version may not have Remote Control'); process.exit(1); }

    const seen = new Set();
    let aCount = 0;

    for (const lit of flagLits) {
        let best = null;
        for (const fn of allFuncDecls) {
            if (fn.start > lit.start || fn.end < lit.end) continue;
            if (!best || (fn.end - fn.start) < (best.end - best.start)) best = fn;
        }
        if (!best || seen.has(best.start)) continue;
        seen.add(best.start);

        const nm = best.id ? best.id.name : '(anon)';
        const stmts = best.body.body;

        // Type A: 0-param, single-return — replace return arg
        if (best.params.length === 0 && stmts.length === 1 &&
            stmts[0].type === 'ReturnStatement' && stmts[0].argument) {
            const retArg = stmts[0].argument;
            if (isReturnTrue(retArg)) continue;
            if (retArg.type === 'CallExpression' || retArg.type === 'LogicalExpression') {
                patches.push({
                    offset: retArg.start, length: retArg.end - retArg.start,
                    replacement: (aCount === 0 ? markers.A : '') + '!0',
                    label: 'A1: ' + (best.async ? 'async ' : '') + nm + '() → !0'
                });
                aCount++; continue;
            }
        }

        // Type B: multi-statement — inject early return
        if (stmts.length > 1) {
            patches.push({
                offset: stmts[0].start, length: 0,
                replacement: (aCount === 0 ? markers.A : '') + 'return!0;',
                label: 'A2: ' + (best.async ? 'async ' : '') + nm + '() → early return !0'
            });
            aCount++;
        }
    }
    patchCount += aCount;
    if (aCount === 0) console.log('WARN:Patch A — no valid targets');
} else console.log('SKIP:A');

// ═════════════════════════════════════════════════════════════
// PATCH B: Policy bypass (allow_remote_sessions / allow_remote_control)
// ═════════════════════════════════════════════════════════════
if (!has.B) {
    console.log('STEP:B - Policy bypass');

    const policyNames = ['allow_remote_sessions', 'allow_remote_control'];
    const detected = policyNames.filter(p => findNodes(ast, n => n.type === 'Literal' && n.value === p).length > 0);
    if (detected.length === 0) { console.error('NOT_FOUND:No policy literals'); process.exit(1); }

    const allCalls = findNodes(ast, n => n.type === 'CallExpression');
    let pfName = null;
    for (const call of allCalls) {
        if (!call.arguments?.length) continue;
        const a0 = call.arguments[0];
        if (a0.type === 'Literal' && a0.value === detected[0] && call.callee.type === 'Identifier') {
            pfName = call.callee.name; break;
        }
    }
    if (!pfName) { console.error('NOT_FOUND:Policy check function'); process.exit(1); }

    let policyFunc = allFuncDecls.find(fn => fn.id?.name === pfName);
    if (!policyFunc || policyFunc.params.length !== 1) { console.error('NOT_FOUND:Policy function decl'); process.exit(1); }

    const param = policyFunc.params[0].name || policyFunc.params[0].left?.name;
    const cond = detected.map(p => param + '==="' + p + '"').join('||');
    const inj = markers.B + 'if(' + cond + ')return!0;';

    patches.push({ offset: policyFunc.body.body[0].start, length: 0, replacement: inj, label: 'B: policy bypass (' + detected.join(' + ') + ')' });
    patchCount++;
} else console.log('SKIP:B');

// ═════════════════════════════════════════════════════════════
// PATCH C: Preflight + getBridgeDisabledReason bypass
// S1K: REPL preflight — hangs on GrowthBook/policy load
// QG8: disabled reason — blocks on feature-flag evaluation
// ═════════════════════════════════════════════════════════════
if (!has.C) {
    console.log('STEP:C - Preflight bypass');

    // C1: S1K (preflight) — async, contains "Prerequisites passed" + "allow_remote_control"
    let preflightFunc = null;
    for (const fn of allFuncDecls) {
        if (!fn.async) continue;
        const s = src(fn);
        if (s.includes('Prerequisites passed') && s.includes('allow_remote_control')) {
            if (!preflightFunc || (fn.end - fn.start) < (preflightFunc.end - preflightFunc.start)) preflightFunc = fn;
        }
    }
    if (preflightFunc) {
        const nm = preflightFunc.id ? preflightFunc.id.name : '(anon)';
        console.log('FOUND:C1 preflight = ' + nm + '()');
        patches.push({ offset: preflightFunc.body.body[0].start, length: 0,
            replacement: markers.C + 'return null;',
            label: 'C1: preflight bypass (' + nm + ')'
        });
        patchCount++;
    } else {
        console.log('WARN:C1 preflight not found');
    }

    // C2: QG8 (disabled reason) — async, contains "feature-flag evaluation" + "tengu_ccr_bridge"
    let reasonFunc = null;
    for (const fn of allFuncDecls) {
        if (!fn.async) continue;
        const s = src(fn);
        if (s.includes('feature-flag evaluation') && s.includes('tengu_ccr_bridge')) {
            if (fn === preflightFunc) continue;
            if (!reasonFunc || (fn.end - fn.start) < (reasonFunc.end - reasonFunc.start)) reasonFunc = fn;
        }
    }
    if (reasonFunc) {
        const nm = reasonFunc.id ? reasonFunc.id.name : '(anon)';
        console.log('FOUND:C2 disabled reason = ' + nm + '()');
        patches.push({ offset: reasonFunc.body.body[0].start, length: 0,
            replacement: 'return null;',
            label: 'C2: disabled reason bypass (' + nm + ')'
        });
        patchCount++;
    } else {
        console.log('WARN:C2 disabled reason not found');
    }
} else console.log('SKIP:C');

// ═════════════════════════════════════════════════════════════
// Apply / Verify
// ═════════════════════════════════════════════════════════════
if (checkOnly) {
    if (patchCount > 0) { console.log('NEEDS_PATCH'); console.log('PATCH_COUNT:' + patchCount); process.exit(1); }
    else { console.log('ALREADY_PATCHED'); process.exit(2); }
}

if (patchCount === 0) { console.log('ALREADY_PATCHED'); process.exit(2); }

patches.sort((a, b) => b.offset - a.offset);
let newCode = code;
for (const p of patches) {
    newCode = newCode.slice(0, p.offset) + p.replacement + newCode.slice(p.offset + p.length);
    console.log('PATCH:' + p.label);
}

console.log('STEP:V - Verifying');
try {
    acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST OK');
} catch (e) {
    console.error('VERIFY_FAILED:' + e.message);
    process.exit(1);
}

for (const [k, v] of Object.entries(markers)) {
    if (patches.find(p => p.label.startsWith(k.toUpperCase())) && !newCode.includes(v)) {
        console.error('VERIFY_FAILED:marker ' + v + ' missing'); process.exit(1);
    }
}

const ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const bak = cliPath + '.' + backupSuffix + '-' + ts;
fs.copyFileSync(cliPath, bak);
console.log('BACKUP:' + bak);
fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchCount);
PATCH_EOF

CHECK_ARG=""
$CHECK_ONLY && CHECK_ARG="--check"
export BACKUP_SUFFIX

EXIT_CODE=0
OUTPUT=$(node "$PATCH_SCRIPT" "$ACORN_PATH" "$CLI_PATH" $CHECK_ARG 2>&1) || EXIT_CODE=$?
rm -f "$PATCH_SCRIPT"

while IFS= read -r line; do
    case "$line" in
        ALREADY_PATCHED)  success "All patches already applied"; exit 0 ;;
        PARSE_ERROR:*)    error "Parse failed: ${line#PARSE_ERROR:}"; exit 1 ;;
        NOT_FOUND:*)      error "${line#NOT_FOUND:}"; exit 1 ;;
        VERSION:*)        info "CC version: ${line#VERSION:}" ;;
        STEP:*)           info "${line#STEP:}" ;;
        FOUND:*)          info "${line#FOUND:}" ;;
        SKIP:*)           info "${line#SKIP:}" ;;
        WARN:*)           warning "${line#WARN:}" ;;
        VERIFY:*)         info "${line#VERIFY:}" ;;
        PATCH:*)          info "Applied: ${line#PATCH:}" ;;
        NEEDS_PATCH)      echo ""; warning "Patches needed — run without --check to apply" ;;
        PATCH_COUNT:*)    info "${line#PATCH_COUNT:} patch(es) pending"; exit 1 ;;
        BACKUP:*)         echo ""; echo "  Backup: ${line#BACKUP:}" ;;
        VERIFY_FAILED:*)  error "Verify failed: ${line#VERIFY_FAILED:}"; exit 1 ;;
        SUCCESS:*)
            echo ""
            success "${line#SUCCESS:} patch(es) applied"
            echo ""
            info "A: Feature flag bypass (tengu_ccr_bridge — sync + async)"
            info "B: Policy bypass (allow_remote_sessions + allow_remote_control)"
            info "C: Preflight + disabled reason bypass"
            echo ""
            info "Usage:"
            echo "  claude remote-control"
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
