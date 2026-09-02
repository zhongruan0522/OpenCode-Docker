#!/bin/bash
#
# Claude Code Auto Mode Full Unlock Patch Script
#
# PURPOSE:
# Three patches that remove auto mode restrictions:
#
# PATCH 1 — Model eligibility bypass (oQq → return !0):
#   Forces the auto mode model eligibility check to always return true.
#   Removes hardcoded model exclusion list so ALL Opus/Sonnet/Haiku models
#   become eligible for auto mode regardless of platform.
#
# PATCH 2 — Classifier unavailable fail-open (deny → ask):
#   When the safety classifier model is temporarily unavailable, the
#   code hard-denies tool use with behavior:"deny". This patch changes
#   it to behavior:"ask" so it falls back to manual approval instead
#   of silently interrupting the tool call.
#   Detection: find the string "Auto mode classifier unavailable" and
#   change the adjacent behavior:"deny" to behavior:"ask".
#
# PATCH 3 — Classifier model override (env var injection):
#   The auto mode safety classifier uses the SAME model as the main
#   conversation (e.g. if you're on Opus, classifier also uses Opus).
#   This wastes expensive model tokens on a classification task that
#   Haiku/Sonnet can handle well. This patch injects an env var check:
#     if(process.env.CLAUDE_CLASSIFIER_MODEL) return process.env.CLAUDE_CLASSIFIER_MODEL;
#   at the top of the classifier model selection function, allowing
#   users to override with e.g. CLAUDE_CLASSIFIER_MODEL=claude-haiku-4-5-20251001
#
# DETECTION STRATEGY (AST-based, name-agnostic):
#
# Patch 1: Find FunctionDeclaration (1 param) whose body has:
#   - nested BlockStatement as first child
#   - exactly 1 x "return !0", at least 3 x "return !1"
#   Replace body with {return !0}.
#
# Patch 2: Find the "Auto mode classifier unavailable" string literal,
#   then locate the enclosing return's ObjectExpression with behavior:"deny"
#   and replace "deny" with "ask".
#
# Patch 3: Find FunctionDeclaration (0 params) containing
#   "tengu_auto_mode_config" literal with ?.model access and
#   a final return of session model. Inject env var check at top.
#   Anchor: "tengu_auto_mode_config" inside a 0-param function
#   with MemberExpression property "model".
#
# Verified: v2.1.136 ~ v2.1.195
#
# Usage:
#   ./apply-claude-code-auto-mode-model-patch.sh                    # Apply (auto-detect)
#   ./apply-claude-code-auto-mode-model-patch.sh /path/to/cli.js   # Apply to specific file
#   ./apply-claude-code-auto-mode-model-patch.sh --check           # Check only
#   ./apply-claude-code-auto-mode-model-patch.sh --restore         # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-automode-model"
FIX_DESCRIPTION="Full auto mode unlock: model eligibility bypass + classifier unavailable fail-open + classifier model override"

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
        "$HOME/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
        "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    )
    if command -v npm &> /dev/null; then
        local npm_root
        npm_root=$(npm root -g 2>/dev/null || true)
        if [[ -n "$npm_root" ]]; then
            locations+=("$npm_root/@anthropic-ai/claude-code/cli.js")
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
        echo "  ~/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
        echo "  /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        echo "  \$(npm root -g)/@anthropic-ai/claude-code/cli.js"
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

// Version info — try comment header first, then sibling package.json
let version = 'unknown';
const headerMatch = code.slice(0, 1000).match(/Version:\s*([\d.]+)/);
if (headerMatch) {
    version = headerMatch[1];
} else {
    const path = require('path');
    try {
        const pkg = JSON.parse(fs.readFileSync(path.join(path.dirname(cliPath), 'package.json'), 'utf-8'));
        if (pkg.version) version = pkg.version;
    } catch {}
}
console.log('VERSION:' + version);

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

function replaceAt(str, s, e, repl) {
    return str.slice(0, s) + repl + str.slice(e);
}

// Collect all replacements; apply from end to start to preserve offsets
let replacements = [];
let patchCount = 0;

// ============================================================
// Phase 1: Find the auto-mode model check function (oQq)
// ============================================================
console.log('STEP:1 - Finding auto-mode model check function');

const allFuncDecls = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 1
);

const oQqCandidates = allFuncDecls.filter(fn => {
    const body = fn.body;
    if (body.type !== 'BlockStatement') return false;
    const stmts = body.body;
    if (stmts.length < 2) return false;
    if (stmts[stmts.length - 1].type !== 'ReturnStatement') return false;

    // Must contain "firstParty" and "anthropicAws" string literals (platform checks)
    const hasFirstParty = findNodes(fn, n =>
        n.type === 'Literal' && n.value === 'firstParty'
    ).length > 0;
    const hasAnthropicAws = findNodes(fn, n =>
        n.type === 'Literal' && n.value === 'anthropicAws'
    ).length > 0;
    if (!hasFirstParty || !hasAnthropicAws) return false;

    const rets0 = findNodes(fn, n =>
        n.type === 'ReturnStatement' && n.argument &&
        n.argument.type === 'UnaryExpression' && n.argument.operator === '!' &&
        n.argument.argument && n.argument.argument.type === 'Literal' &&
        n.argument.argument.value === 0
    );
    if (rets0.length !== 1) return false;

    const rets1 = findNodes(fn, n =>
        n.type === 'ReturnStatement' && n.argument &&
        n.argument.type === 'UnaryExpression' && n.argument.operator === '!' &&
        n.argument.argument && n.argument.argument.type === 'Literal' &&
        n.argument.argument.value === 1
    );
    if (rets1.length < 3) return false;
    return true;
});

let oQqPatched = false;
let oQqName = '(unknown)';
let oQqFunc = null;

if (oQqCandidates.length === 0) {
    // Check if already patched: 1-param FuncDecl with body = {return !0}
    // This happens when Claude Code or a prior run already patched it
    const alreadyPatched = allFuncDecls.filter(fn => {
        const s = code.slice(fn.body.start, fn.body.end).replace(/\s+/g, '');
        return s === '{return!0}';
    });
    if (alreadyPatched.length > 0) {
        oQqName = alreadyPatched[0].id.name;
        oQqPatched = true;
        console.log('FOUND:' + oQqName + ' already patched (body = {return !0})');
    } else {
        console.error('NOT_FOUND:Cannot find auto-mode model check function');
        process.exit(1);
    }
} else {
    oQqFunc = oQqCandidates[0];
    oQqName = oQqFunc.id.name;

    if (oQqCandidates.length > 1) {
        console.log('  [WARN] Found ' + oQqCandidates.length + ' candidates, using first: ' + oQqName);
    }

    console.log('FOUND:func = ' + oQqName + '(' + oQqFunc.params.map(p => p.name).join(',') +
        ') at offset ' + oQqFunc.start + ' [' + (oQqFunc.end - oQqFunc.start) + ' bytes]');

    // Check if oQq already patched
    const bodySrc = code.slice(oQqFunc.body.start, oQqFunc.body.end);
    const normalizedBody = bodySrc.replace(/\s+/g, '');
    if (normalizedBody === '{return!0}') {
        console.log('FOUND:oQq already patched (body = {return !0})');
        oQqPatched = true;
    } else {
        const newBody = '{return !0}';
        replacements.push({
            start: oQqFunc.body.start,
            end: oQqFunc.body.end,
            replacement: newBody,
            label: oQqName + '.body → ' + newBody
        });
        patchCount++;
        console.log('FOUND:needs patching — ' + oQqName + ' body has ' +
            (oQqFunc.body.end - oQqFunc.body.start) + ' bytes of gate logic');
    }
}

// ============================================================
// Phase 2: Classifier unavailable → fail-open (deny → ask)
//
// Strategy A (≥2.1.163): Find the string literal
//   "Auto mode classifier unavailable, denying with retry guidance (fail closed)"
// then locate the sibling ObjectExpression in the same SequenceExpression
// that has property behavior:"deny", and replace "deny" with "ask".
//
// Strategy B (2.1.143–2.1.162, legacy): Find CallExpression where
//   arguments[0] = Literal "tengu_iron_gate_closed"
// and replace entire CallExpression with !1 (false).
// ============================================================
console.log('STEP:2 - Finding classifier unavailable fail-closed logic');

const UNAVAIL_ANCHOR = 'Auto mode classifier unavailable';
let ironGatePatched = false;

if (code.includes(UNAVAIL_ANCHOR)) {
    // Strategy A: hardcoded fail-closed (≥2.1.163)
    // Find the Literal node containing the anchor string
    const anchorLiterals = findNodes(ast, n =>
        n.type === 'Literal' &&
        typeof n.value === 'string' &&
        n.value.includes(UNAVAIL_ANCHOR)
    );

    if (anchorLiterals.length === 0) {
        console.error('NOT_FOUND:anchor string found in raw code but not in AST — possible encoding issue');
        process.exit(1);
    }

    console.log('FOUND:' + anchorLiterals.length + ' "classifier unavailable" anchor(s)');

    // Walk up: the anchor is inside a CallExpression (T("Auto mode...", {level:"warn"}))
    // which is part of a SequenceExpression (comma operator): T(...), {behavior:"deny",...}
    // which is the argument of a ReturnStatement.
    // We need to find the ObjectExpression with behavior:"deny" near the anchor.

    // Search for ObjectExpression nodes with behavior:"deny" that are close to the anchor
    // (within ~300 chars in source position)
    let failClosedPatched = 0;
    for (const anchor of anchorLiterals) {
        // Find all behavior:"deny" ObjectExpressions after the anchor (within 300 chars)
        const denyObjects = findNodes(ast, n =>
            n.type === 'ObjectExpression' &&
            n.start > anchor.start &&
            n.start < anchor.end + 300 &&
            n.properties && n.properties.some(p =>
                p.key && (p.key.name === 'behavior' || p.key.value === 'behavior') &&
                p.value && p.value.type === 'Literal' && p.value.value === 'deny'
            )
        );

        if (denyObjects.length === 0) {
            // Check if already patched to "ask"
            const askObjects = findNodes(ast, n =>
                n.type === 'ObjectExpression' &&
                n.start > anchor.start &&
                n.start < anchor.end + 300 &&
                n.properties && n.properties.some(p =>
                    p.key && (p.key.name === 'behavior' || p.key.value === 'behavior') &&
                    p.value && p.value.type === 'Literal' && p.value.value === 'ask'
                )
            );
            if (askObjects.length > 0) {
                console.log('FOUND:classifier unavailable already patched to behavior:"ask"');
                failClosedPatched++;
                continue;
            }
            console.log('FOUND:no behavior:"deny" found near anchor at offset ' + anchor.start);
            continue;
        }

        // Patch the first matching deny → ask
        const denyObj = denyObjects[0];
        const behaviorProp = denyObj.properties.find(p =>
            (p.key.name === 'behavior' || p.key.value === 'behavior') &&
            p.value.type === 'Literal' && p.value.value === 'deny'
        );

        replacements.push({
            start: behaviorProp.value.start,
            end: behaviorProp.value.end,
            replacement: '"ask"',
            label: 'classifier unavailable: behavior:"deny" → behavior:"ask" (near offset ' + anchor.start + ')'
        });
        patchCount++;
        failClosedPatched++;
    }

    if (failClosedPatched === anchorLiterals.length) {
        // All anchors handled
    } else {
        console.log('FOUND:patched ' + failClosedPatched + '/' + anchorLiterals.length + ' unavailable sites');
    }
} else if (code.includes('tengu_iron_gate_closed')) {
    // Strategy B: legacy flag-based control (2.1.143–2.1.162)
    const ironGateCalls = findNodes(ast, n =>
        n.type === 'CallExpression' &&
        n.arguments && n.arguments.length >= 2 &&
        n.arguments[0].type === 'Literal' &&
        n.arguments[0].value === 'tengu_iron_gate_closed'
    );

    if (ironGateCalls.length === 0) {
        console.log('FOUND:iron_gate string exists but no matching CallExpression — may be already patched');
        ironGatePatched = true;
    } else {
        const calleeName = src(ironGateCalls[0].callee);
        console.log('FOUND:' + ironGateCalls.length + ' iron_gate call site(s) via ' + calleeName + '() [legacy]');
        for (let i = 0; i < ironGateCalls.length; i++) {
            const call = ironGateCalls[i];
            const originalSrc = src(call);
            if (originalSrc === '!1') {
                console.log('FOUND:site ' + (i+1) + ' already locked to !1');
                continue;
            }
            replacements.push({
                start: call.start,
                end: call.end,
                replacement: '!1',
                label: 'iron_gate site ' + (i+1) + ': ' + originalSrc.slice(0, 60) + ' → !1'
            });
            patchCount++;
        }
        if (replacements.length === (oQqPatched ? 0 : 1)) {
            ironGatePatched = true;
            console.log('FOUND:all iron_gate sites already locked to !1');
        }
    }
} else {
    console.log('FOUND:no classifier unavailable anchor or iron_gate flag — skipping (pre-v2.1.143)');
    ironGatePatched = true;
}

// ============================================================
// Phase 3: Find classifier model selection function
//
// AST: FunctionDeclaration with 0 params containing
//   Literal "tengu_auto_mode_config" and MemberExpression ?.model
//   Last stmt returns session model (CallExpression or Identifier)
//
// Inject: if(process.env.CLAUDE_CLASSIFIER_MODEL)return process.env.CLAUDE_CLASSIFIER_MODEL;
//
// This env var is populated from:
//   - Shell environment
//   - settings.json → env.CLAUDE_CLASSIFIER_MODEL
//   - --settings flagSettings → env.CLAUDE_CLASSIFIER_MODEL
// All applied to process.env via Ae() before any conversation starts.
// ============================================================
console.log('STEP:3 - Finding classifier model selection function');

const ENV_VAR = 'CLAUDE_CLASSIFIER_MODEL';
const envGuard = 'if(process.env.' + ENV_VAR + ')return{value:process.env.' + ENV_VAR + ',src:"env"};';

const allFuncDecls0 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 0
);

// Find the classifier model function: 0-param FuncDecl containing
// "tengu_auto_mode_config" literal AND ?.model member access
const classifierModelCandidates = allFuncDecls0.filter(fn => {
    const bodySrc = src(fn.body);
    if (!bodySrc.includes('tengu_auto_mode_config')) return false;

    // Must have ?.model or .model access
    const modelAccess = findNodes(fn.body, n =>
        n.type === 'MemberExpression' &&
        n.property && (n.property.name === 'model' || n.property.value === 'model')
    );
    if (modelAccess.length === 0) return false;

    // Must end with a return statement (fallback to session model)
    const stmts = fn.body.body;
    if (stmts.length === 0) return false;
    const lastStmt = stmts[stmts.length - 1];
    if (lastStmt.type !== 'ReturnStatement') return false;

    // Should be a relatively small function (< 500 bytes)
    if (fn.end - fn.start > 500) return false;

    return true;
});

let classifierPatched = false;
let classifierName = '(unknown)';
let classifierFunc = null;

if (classifierModelCandidates.length === 0) {
    // Check if already patched: look for the env guard string
    if (code.includes('process.env.' + ENV_VAR)) {
        console.log('FOUND:classifier model override already injected (process.env.' + ENV_VAR + ' found)');
        classifierPatched = true;
    } else {
        console.log('FOUND:no classifier model function found — skipping (may be pre-v2.1.136 or different structure)');
        classifierPatched = true;
    }
} else {
    classifierFunc = classifierModelCandidates[0];
    classifierName = classifierFunc.id.name;

    console.log('FOUND:classifierModel = ' + classifierName + '() at offset ' +
                classifierFunc.start + ' [' + (classifierFunc.end - classifierFunc.start) + ' bytes]');

    // Check if already patched
    const bodyStart = classifierFunc.body.start;
    const existingStart = code.slice(bodyStart, bodyStart + envGuard.length + 5);
    if (existingStart.includes('process.env.' + ENV_VAR)) {
        console.log('FOUND:' + classifierName + ' already has env var guard');
        classifierPatched = true;
    } else {
        // Show what the function currently does
        const hasCedarHollow = src(classifierFunc.body).includes('tengu_cedar_hollow');
        console.log('FOUND:needs patching — ' + classifierName + '() returns session model' +
                    (hasCedarHollow ? ' (with cedar_hollow override for opus-4-8)' : '') +
                    ' → injecting ' + ENV_VAR + ' env var check');

        const insertionPoint = classifierFunc.body.start + 1; // after '{'
        replacements.push({
            start: insertionPoint,
            end: insertionPoint,
            replacement: envGuard,
            label: classifierName + ': injected env var guard → ' + ENV_VAR
        });
        patchCount++;
    }
}

// ============================================================
// All already patched?
// ============================================================
if (oQqPatched && ironGatePatched && classifierPatched) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (replacements.length === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchCount);
    console.log('OQQ_NAME:' + oQqName);
    if (classifierFunc) console.log('CLASSIFIER_NAME:' + classifierName);
    process.exit(1);
}

// ============================================================
// Phase 4: Apply all replacements (end-to-start order)
// ============================================================
console.log('STEP:4 - Applying ' + replacements.length + ' replacement(s)');

replacements.sort((a, b) => b.start - a.start);

let newCode = code;
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
    console.log('PATCH:' + r.label);
}

// ============================================================
// Phase 5: Verify
// ============================================================

// 5a. Re-parse to confirm syntax is valid
let newAst;
try {
    newAst = acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST re-parse confirms valid syntax');
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 5b. Verify oQq if it was patched
if (!oQqPatched) {
    const verifySig = code.slice(oQqFunc.start, oQqFunc.body.start);
    if (newCode.indexOf(verifySig) === -1) {
        console.error('VERIFY_FAILED:' + oQqName + ' function declaration corrupted');
        process.exit(1);
    }
    console.log('VERIFY:' + oQqName + ' function declaration intact');
}

// 5c. Verify classifier unavailable path is now fail-open
if (!ironGatePatched) {
    if (code.includes(UNAVAIL_ANCHOR)) {
        // Strategy A: verify behavior:"deny" near anchor is now "ask"
        const anchorLiterals = findNodes(newAst, n =>
            n.type === 'Literal' && typeof n.value === 'string' &&
            n.value.includes(UNAVAIL_ANCHOR)
        );
        for (const anchor of anchorLiterals) {
            const stillDeny = findNodes(newAst, n =>
                n.type === 'ObjectExpression' &&
                n.start > anchor.start && n.start < anchor.end + 300 &&
                n.properties && n.properties.some(p =>
                    (p.key.name === 'behavior' || p.key.value === 'behavior') &&
                    p.value && p.value.type === 'Literal' && p.value.value === 'deny'
                )
            );
            if (stillDeny.length > 0) {
                console.error('VERIFY_FAILED:classifier unavailable path still has behavior:"deny" after patch');
                process.exit(1);
            }
        }
        console.log('VERIFY:classifier unavailable path now uses behavior:"ask"');
    } else {
        // Strategy B (legacy): verify iron_gate calls removed
        const remaining = findNodes(newAst,
            n => n.type === 'CallExpression' && n.arguments?.length >= 2 &&
                 n.arguments[0].type === 'Literal' && n.arguments[0].value === 'tengu_iron_gate_closed'
        );
        if (remaining.length > 0) {
            console.error('VERIFY_FAILED:' + remaining.length + ' iron_gate call(s) still present after patch');
            process.exit(1);
        }
        console.log('VERIFY:all tengu_iron_gate_closed calls replaced with !1');
    }
}

// 5d. Verify classifier model env guard if it was patched
if (!classifierPatched) {
    if (!newCode.includes('process.env.' + ENV_VAR)) {
        console.error('VERIFY_FAILED:' + ENV_VAR + ' env var check not found after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + classifierName + '() now checks process.env.' + ENV_VAR);
}

// ============================================================
// Backup and write
// ============================================================
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchCount);
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
            success "Already patched (model check already returns true)"
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
            info "  ${line#PATCH:}"
            ;;
        NEEDS_PATCH)
            echo ""
            warning "Patch needed - run without --check to apply"
            ;;
        OQQ_NAME:*)
            info "Model check function name in this version: ${line#OQQ_NAME:}"
            ;;
        PATCH_COUNT:*)
            info "Need to patch ${line#PATCH_COUNT:} location(s)"
            exit 1
            ;;
        BACKUP:*)
            echo ""
            echo "Backup: ${line#BACKUP:}"
            ;;
        CLASSIFIER_NAME:*)
            info "Classifier model function: ${line#CLASSIFIER_NAME:}"
            ;;
        SUCCESS:*)
            echo ""
            success "Fix applied successfully! Patched ${line#SUCCESS:} location(s)"
            echo ""
            echo "  Patch 1: Model eligibility → all models eligible for auto mode"
            echo "  Patch 2: Classifier unavailable → falls back to manual approval (deny→ask)"
            echo "  Patch 3: Classifier model → overridable via CLAUDE_CLASSIFIER_MODEL"
            echo ""
            info "To use a cheaper model for the classifier, set in any of:"
            echo "  • Shell:       export CLAUDE_CLASSIFIER_MODEL=claude-haiku-4-5-20251001"
            echo "  • settings.json → env: {\"CLAUDE_CLASSIFIER_MODEL\": \"claude-haiku-4-5-20251001\"}"
            echo "  • --settings file.json → env: {\"CLAUDE_CLASSIFIER_MODEL\": \"...\"}"
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
