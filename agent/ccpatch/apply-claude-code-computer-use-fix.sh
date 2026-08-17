#!/bin/bash
#
# Claude Code Computer Use Settings Externalization Patch
#
# Externalizes the Computer Use MCP enable/config gate so it can be
# controlled via settings.json / env-var instead of requiring a Max/Pro
# subscription + server-side feature-flag.
#
# WHAT IT DOES (AST-precise patches):
# 1) Registers `computerUseEnabled` + `computerUseConfig` in settings Zod schema
# 2) Rewrites t0n() to read env-var → settings → original logic (3-tier)
# 4) Rewrites s7r() to merge user-supplied `computerUseConfig` overrides
#
# Default is OFF — identical to stock behaviour.  Users opt-in via:
#   settings.json:  { "computerUseEnabled": true }
#   env-var:        CLAUDE_CODE_COMPUTER_USE=1
#   sub-config:     { "computerUseConfig": { "mouseAnimation": false } }
#
# Usage:
#   ./apply-claude-code-computer-use-fix.sh                    # Apply fix (auto-detect)
#   ./apply-claude-code-computer-use-fix.sh /path/to/cli.js    # Apply fix to specific file
#   ./apply-claude-code-computer-use-fix.sh --check            # Check only
#   ./apply-claude-code-computer-use-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-computer-use"
FIX_DESCRIPTION="Externalize Computer Use MCP gate to settings.json (default off)"

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
            echo "After patching, enable Computer Use via:"
            echo "  settings.json:  { \"computerUseEnabled\": true }"
            echo "  env-var:        CLAUDE_CODE_COMPUTER_USE=1 claude"
            echo "  sub-config:     { \"computerUseConfig\": { \"mouseAnimation\": false } }"
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
# Node.js AST patch script
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

const src = (node) => code.slice(node.start, node.end);

// ============================================================
// AST walker
// ============================================================
function walk(node, visitor, parent) {
    if (!node || typeof node !== 'object') return;
    if (node.type) visitor(node, parent);
    for (const k of Object.keys(node)) {
        const c = node[k];
        if (Array.isArray(c)) c.forEach(x => walk(x, visitor, node));
        else if (c && typeof c === 'object' && c.type) walk(c, visitor, node);
    }
}

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

// ============================================================
// Fix tracking + AST node storage
// ============================================================
let fixes = {
    schema: { found: false, patched: false, node: null, parentNode: null },
    t0n:    { found: false, patched: false, node: null },
    s7r:    { found: false, patched: false, node: null },
};

// Dynamically extracted variable/function names (differ across minified versions)
let zodVar = null;   // Zod builder: b, v, k, ...
let stFn = null;     // truthy env-var parser: st, A6, ...
let ScFn = null;     // settings reader: Sc, K4, ...

// Already-patched sentinels
const SENTINEL_T0N = 'CLAUDE_CODE_COMPUTER_USE';
const SENTINEL_S7R = '"computerUseConfig"';

// ============================================================
// Extract st() and Sc() equivalents from the YC-equivalent function
//   YC-equivalent: the FunctionDeclaration whose body contains both
//     "autoCompactEnabled" and "DISABLE_AUTO_COMPACT"
//   Inside it:
//     st-equiv = callee of CallExpression(arg includes DISABLE_AUTO_COMPACT)
//     Sc-equiv = callee of CallExpression(arg[0] === "autoCompactEnabled")
// ============================================================
walk(ast, (node) => {
    if (stFn && ScFn) return;
    if (node.type !== 'FunctionDeclaration') return;
    const body = src(node);
    if (!body.includes('"autoCompactEnabled"')) return;
    if (!body.includes('DISABLE_AUTO_COMPACT')) return;

    walk(node, (n) => {
        if (n.type !== 'CallExpression' || n.callee?.type !== 'Identifier') return;
        const argSrc = n.arguments?.[0] ? src(n.arguments[0]) : '';
        if (!stFn && argSrc.includes('DISABLE_AUTO_COMPACT')) stFn = n.callee.name;
        if (!ScFn && n.arguments?.[0]?.value === 'autoCompactEnabled') ScFn = n.callee.name;
    });
    if (stFn && ScFn) {
        console.log('FOUND:helpers — st=' + stFn + ', Sc=' + ScFn +
            ' (from YC-equivalent: ' + node.id?.name + ')');
    }
});
if (!stFn || !ScFn) {
    console.error('NOT_FOUND:Could not extract st/Sc function names from YC-equivalent. Version unsupported.');
    process.exit(1);
}

// ============================================================
// Helper: extract Zod root variable from a CallExpression chain
//   e.g. b.boolean().optional().describe(...)
//   walks callee.object until hitting an Identifier → returns its name
// ============================================================
function extractZodVar(callExpr) {
    let cur = callExpr;
    while (cur?.type === 'CallExpression' && cur.callee?.type === 'MemberExpression') {
        cur = cur.callee.object;
    }
    return cur?.type === 'Identifier' ? cur.name : null;
}

// ============================================================
// Patch 1 — Locate autoCompactEnabled Property in settings schema
//
// AST shape:
//   Property {
//     key: Identifier { name: "autoCompactEnabled" },
//     value: CallExpression  (the <zod>.boolean().optional().describe(...) chain)
//   }
//   inside an ObjectExpression with 100+ properties (the settings schema)
//
// Also extracts the Zod variable name (b, v, k, etc.) from the value chain
// ============================================================
walk(ast, (node, parent) => {
    if (fixes.schema.found) return;
    if (node.type !== 'Property') return;
    if (node.key?.type !== 'Identifier' || node.key.name !== 'autoCompactEnabled') return;
    if (node.value?.type !== 'CallExpression') return;
    if (parent?.type !== 'ObjectExpression' || parent.properties.length < 50) return;
    const valSrc = src(node.value);
    if (!valSrc.includes('compact conversation')) return;

    // Extract Zod variable name from the value CallExpression chain
    const extracted = extractZodVar(node.value);
    if (!extracted) {
        console.error('NOT_FOUND:Could not extract Zod variable name from autoCompactEnabled value');
        process.exit(1);
    }
    zodVar = extracted;

    fixes.schema.found = true;
    fixes.schema.node = node;
    fixes.schema.parentNode = parent;
    console.log('FOUND:schema — Property[autoCompactEnabled] at ' + node.start +
        ' (parent ObjectExpression has ' + parent.properties.length + ' props, zod=' + zodVar + ')');
});

// ============================================================
// Patch 4 — Locate s7r-equivalent FunctionDeclaration (MUST run before Patch 2)
//
// Name-independent structural match:
//   FunctionDeclaration {
//     body.body = [ReturnStatement {
//       argument: ObjectExpression {
//         properties: [
//           SpreadElement { argument: Identifier },          (the config defaults var)
//           SpreadElement { argument: CallExpression {
//             arguments: [Literal("tengu_malort_pedway"), Identifier]  (same defaults var)
//           }}
//         ]
//       }
//     }]
//   }
// ============================================================
let s7rFnName = null;
walk(ast, (node) => {
    if (fixes.s7r.found) return;
    if (node.type !== 'FunctionDeclaration') return;
    const stmts = node.body?.body;
    if (!stmts || stmts.length !== 1) return;
    const ret = stmts[0];
    if (ret.type !== 'ReturnStatement') return;
    const obj = ret.argument;
    if (obj?.type !== 'ObjectExpression') return;
    if (obj.properties.length !== 2) return;
    const sp0 = obj.properties[0];
    if (sp0.type !== 'SpreadElement' || sp0.argument?.type !== 'Identifier') return;
    const sp1 = obj.properties[1];
    if (sp1.type !== 'SpreadElement' || sp1.argument?.type !== 'CallExpression') return;
    // Key: the call must have "tengu_malort_pedway" as first argument
    if (sp1.argument.arguments?.[0]?.value !== 'tengu_malort_pedway') return;
    // And the second argument must be the same Identifier as sp0
    if (sp1.argument.arguments?.[1]?.name !== sp0.argument.name) return;

    fixes.s7r.found = true;
    fixes.s7r.node = node;
    s7rFnName = node.id?.name;
    console.log('FOUND:s7r — ' + s7rFnName + '() at ' + node.start +
        ' [return{...' + sp0.argument.name + ',...' + sp1.argument.callee?.name +
        '("tengu_malort_pedway",' + sp0.argument.name + ')}]');
});

// ============================================================
// Patch 2 — Locate t0n-equivalent FunctionDeclaration
//
// Name-independent structural match:
//   FunctionDeclaration {
//     body.body = [ReturnStatement {
//       argument: LogicalExpression {
//         operator: "&&",
//         left: CallExpression { callee: Identifier },        (the t5d-equiv)
//         right: MemberExpression {
//           object: CallExpression { callee: Identifier },    (MUST be s7r-equiv name)
//           property: Identifier { name: "enabled" }
//         }
//       }
//     }]
//   }
// ============================================================
walk(ast, (node) => {
    if (fixes.t0n.found) return;
    if (node.type !== 'FunctionDeclaration') return;
    const stmts = node.body?.body;
    if (!stmts || stmts.length !== 1) return;
    const ret = stmts[0];
    if (ret.type !== 'ReturnStatement') return;
    const arg = ret.argument;
    if (arg?.type !== 'LogicalExpression' || arg.operator !== '&&') return;
    if (arg.left?.type !== 'CallExpression' || arg.left.callee?.type !== 'Identifier') return;
    if (arg.right?.type !== 'MemberExpression') return;
    if (arg.right.object?.type !== 'CallExpression' || arg.right.object.callee?.type !== 'Identifier') return;
    if (arg.right.property?.name !== 'enabled') return;
    // Cross-check: right-side callee must be the s7r-equivalent we found above
    if (s7rFnName && arg.right.object.callee.name !== s7rFnName) return;

    fixes.t0n.found = true;
    fixes.t0n.node = node;
    const t5dName = arg.left.callee.name;
    console.log('FOUND:t0n — ' + node.id?.name + '() at ' + node.start +
        ' [return ' + t5dName + '()&&' + arg.right.object.callee.name + '().enabled]');
});

// ============================================================
// Check already-patched
// ============================================================
if (code.includes(SENTINEL_T0N))    { fixes.t0n.found = true;    fixes.t0n.patched = true;    console.log('FOUND:t0n — already patched (sentinel)'); }
if (code.includes(SENTINEL_S7R))    { fixes.s7r.found = true;    fixes.s7r.patched = true;    console.log('FOUND:s7r — already patched (sentinel)'); }
// Schema sentinel: check if computerUseEnabled already exists as a Property key in schema
let schemaAlreadyPatched = false;
walk(ast, (node, parent) => {
    if (schemaAlreadyPatched) return;
    if (node.type === 'Property' && node.key?.name === 'computerUseEnabled'
        && parent?.type === 'ObjectExpression' && parent.properties.length >= 50) {
        schemaAlreadyPatched = true;
    }
});
if (schemaAlreadyPatched) { fixes.schema.found = true; fixes.schema.patched = true; console.log('FOUND:schema — already patched (sentinel)'); }

const allAlreadyPatched = Object.values(fixes).every(f => f.found && f.patched);
if (allAlreadyPatched) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

const anyNeedsPatch = Object.values(fixes).some(f => f.found && !f.patched);
if (!anyNeedsPatch) {
    const missing = Object.entries(fixes).filter(([,f]) => !f.found).map(([k]) => k).join(', ');
    console.error('NOT_FOUND:Could not locate AST nodes for: ' + missing + '. Version may be unsupported.');
    process.exit(1);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = Object.values(fixes).filter(f => f.found && !f.patched).length;
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

// ============================================================
// Build replacements (applied end→start to preserve offsets)
// ============================================================
let replacements = [];

// --- Patch 1: insert after autoCompactEnabled Property.end ---
if (fixes.schema.found && !fixes.schema.patched && fixes.schema.node) {
    if (!zodVar) {
        console.error('VERIFY_FAILED:Zod variable name not extracted — cannot generate schema insertion');
        process.exit(1);
    }
    const z = zodVar;
    const insertAfter = fixes.schema.node.end;
    const insertion =
        ',computerUseEnabled:' + z + '.boolean().optional().describe("Enable computer use MCP server for desktop control (macOS only, default off)")' +
        ',computerUseConfig:' + z + '.object({mouseAnimation:' + z + '.boolean().optional(),' +
        'hideBeforeAction:' + z + '.boolean().optional(),' +
        'clipboardGuard:' + z + '.boolean().optional(),' +
        'coordinateMode:' + z + '.enum(["pixels","normalized_0_100"]).optional()' +
        '}).optional().describe("Computer use sub-configuration overrides")';
    replacements.push({
        start: insertAfter,
        end: insertAfter,
        text: insertion,
        name: 'schema'
    });
    fixes.schema.patched = true;
    console.log('PATCH:schema — inserted computerUseEnabled + computerUseConfig (zod=' + z + ')');
}

// --- Patch 2: replace entire t0n FunctionDeclaration ---
//     Uses dynamically extracted stFn (st-equiv) and ScFn (Sc-equiv)
if (fixes.t0n.found && !fixes.t0n.patched && fixes.t0n.node) {
    const fn = fixes.t0n.node;
    const fnName = fn.id.name;
    // Recover t5d/s7r callee names from original AST node
    const ret = fn.body.body[0].argument;
    const t5dName = ret.left.callee.name;
    const s7rName = ret.right.object.callee.name;
    const replacement =
        'function ' + fnName + '(){' +
            'if(' + stFn + '(process.env.CLAUDE_CODE_COMPUTER_USE))return!0;' +
            'var _cu=' + ScFn + '("computerUseEnabled",void 0);' +
            'if(_cu.source!=="default")return!!_cu.value;' +
            'return ' + t5dName + '()&&' + s7rName + '().enabled' +
        '}';
    replacements.push({
        start: fn.start,
        end: fn.end,
        text: replacement,
        name: 't0n'
    });
    fixes.t0n.patched = true;
    console.log('PATCH:t0n — env(' + stFn + ') → settings(' + ScFn + ') → original 3-tier gate');
}

// --- Patch 4: replace entire s7r FunctionDeclaration ---
//     Uses dynamically extracted ScFn (Sc-equiv)
//     Recovers jna-equiv and BR-equiv names from original AST node
if (fixes.s7r.found && !fixes.s7r.patched && fixes.s7r.node) {
    const fn = fixes.s7r.node;
    const fnName = fn.id.name;
    const retObj = fn.body.body[0].argument;
    const jnaName = retObj.properties[0].argument.name;
    const BRName = retObj.properties[1].argument.callee.name;
    const replacement =
        'function ' + fnName + '(){' +
            'var _b={...' + jnaName + ',...' + BRName + '("tengu_malort_pedway",' + jnaName + ')};' +
            'var _uo=' + ScFn + '("computerUseConfig",void 0);' +
            'if(_uo.source!=="default"&&typeof _uo.value==="object"&&_uo.value!==null)' +
                'return{..._b,..._uo.value};' +
            'return _b' +
        '}';
    replacements.push({
        start: fn.start,
        end: fn.end,
        text: replacement,
        name: 's7r'
    });
    fixes.s7r.patched = true;
    console.log('PATCH:s7r — computerUseConfig settings merge (Sc=' + ScFn + ')');
}

// ============================================================
// Apply replacements end→start
// ============================================================
replacements.sort((a, b) => b.start - a.start);
let newCode = code;
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.text + newCode.slice(r.end);
}

// ============================================================
// Post-patch verification: re-parse to ensure valid JS
// ============================================================
try {
    acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// ============================================================
// Save
// ============================================================
const patchedCount = Object.values(fixes).filter(f => f.patched).length;
const failedNames = Object.entries(fixes)
    .filter(([, f]) => f.found && !f.patched)
    .map(([name]) => name);

if (patchedCount === 0) {
    console.error('VERIFY_FAILED:No fixes were applied');
    process.exit(1);
}
if (failedNames.length > 0) {
    console.log('WARN:partial — could not patch: ' + failedNames.join(', '));
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
            echo ""
            echo "  To enable:  settings.json → { \"computerUseEnabled\": true }"
            echo "  Or:         CLAUDE_CODE_COMPUTER_USE=1 claude"
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
        WARN:*)
            warning "${line#WARN:}"
            ;;
        NEEDS_PATCH)
            echo ""
            warning "Patch needed — run without --check to apply"
            ;;
        PATCH_COUNT:*)
            info "Need to patch ${line#PATCH_COUNT:} location(s)"
            exit 1
            ;;
        BACKUP:*)
            echo ""
            echo "  Backup: ${line#BACKUP:}"
            ;;
        SUCCESS:*)
            echo ""
            success "Fix applied! Patched ${line#SUCCESS:} location(s)"
            echo ""
            echo "  Usage:"
            echo "    settings.json → { \"computerUseEnabled\": true }"
            echo "    or: CLAUDE_CODE_COMPUTER_USE=1 claude"
            echo ""
            echo "    Sub-config (optional):"
            echo "    { \"computerUseConfig\": { \"mouseAnimation\": false } }"
            echo ""
            warning "Restart Claude Code for changes to take effect"
            warning "macOS only — requires Accessibility + Screen Recording permissions"
            ;;
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
