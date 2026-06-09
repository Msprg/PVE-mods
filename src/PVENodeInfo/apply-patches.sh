#!/usr/bin/env bash
# /usr/lib/pve-mod/apply-patches.sh
#
# Applies pve-mod patches to Proxmox VE system files.
# Reads /etc/pve-mod/pve-mod.conf to determine which modules are enabled.
# Idempotent: safe to call multiple times (e.g. from apt hook after PVE upgrade).

CONF_FILE="/etc/pve-mod/pve-mod.conf"
BACKUP_DIR="/var/lib/pve-mod/backup"
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PVE_MOD_JS="/usr/share/pve-manager/js/PveMod_PveNodeStatusView.js"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PROXMOXLIB_MIN_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"
GPU_RRD_DIR="/var/lib/rrdcached/db/pve-mod-gpu"

info() { echo "[pve-mod] $*"; }
warn() { echo "[pve-mod] WARNING: $*" >&2; }

# Read one value from the INI config file; prints $default if not found.
read_conf() {
    local section="$1" key="$2" default="${3:-0}"
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "$default"
        return
    fi
    local val
    val=$(awk -F= -v sec="[$section]" -v k="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == k) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                print $2; exit
            }
        }
    ' "$CONF_FILE")
    echo "${val:-$default}"
}

backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local name ts
    name=$(basename "$src")
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"
    cp "$src" "$BACKUP_DIR/${name}.${ts}"
    info "Backed up $(basename "$src") → $BACKUP_DIR/${name}.${ts}"
}

# ── Read enabled modules ──────────────────────────────────────────────────────
NODE_INFO=$(read_conf modules node_info 0)
NAG_SCREEN=$(read_conf modules nag_screen 0)
GPU_HISTORY=$(read_conf gpu gpu_history 0)
MIGRATE_STORAGE=$(read_conf modules migrate_storage 0)

CHANGED=false

# ── node-info: Nodes.pm ───────────────────────────────────────────────────────
if [[ "$NODE_INFO" == "1" ]]; then
    if ! grep -qF "use PVE::API2::PVEMod_SensorInfo" "$NODES_PM" 2>/dev/null; then
        backup_file "$NODES_PM"
        python3 - "$NODES_PM" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'use PVE::API2::PVEMod_SensorInfo' in content:
    sys.exit(0)

m = re.search(r'^([ \t]*)my \$dinfo = df\(\'\/\', 1\);', content, re.MULTILINE)
if not m:
    print("ERROR: Anchor 'my $dinfo = df' not found in Nodes.pm", file=sys.stderr)
    sys.exit(1)

indent = m.group(1)
insertion = (
    f"{indent}# Collect sensor data from PveMod_SensorInfo\n"
    f"{indent}use PVE::API2::PVEMod_SensorInfo;\n"
    f"{indent}$res->{{PveMod_JsonSensorInfo}} = PVE::API2::PVEMod_SensorInfo::get_sensors_info();\n"
    f"{indent}$res->{{PveMod_Version}} = PVE::API2::PVEMod_SensorInfo::get_pve_mod_version();\n"
    f"{indent}$res->{{PveMod_graphicsInfo}} = PVE::API2::PVEMod_SensorInfo::get_graphics_info();\n"
    f"{indent}$res->{{PveMod_upsInfo}} = PVE::API2::PVEMod_SensorInfo::get_ups_info();\n"
    f"{indent}$res->{{PveMod_systemInfo}} = PVE::API2::PVEMod_SensorInfo::get_system_information();\n"
)
content = content[:m.start()] + insertion + content[m.start():]
open(path, 'w').write(content)
PYEOF
        info "Patched Nodes.pm"
        CHANGED=true
    fi

    # ── node-info: pvemanagerlib.js ───────────────────────────────────────────
    if ! grep -qF "PveMod_PveNodeStatusView.js" "$PVE_MANAGER_JS" 2>/dev/null; then
        backup_file "$PVE_MANAGER_JS"
        python3 - "$PVE_MANAGER_JS" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'PveMod_PveNodeStatusView.js' in content:
    sys.exit(0)

# Comment out original StatusView definition
content = re.sub(
    r"(?m)^(Ext\.define\('PVE\.node\.StatusView',.*?^}\);)",
    lambda m: '\n'.join('// ' + line for line in m.group(1).split('\n')),
    content, flags=re.DOTALL
)

# Comment out original Summary definition
content = re.sub(
    r"(?m)^(Ext\.define\('PVE\.node\.Summary',.*?^}\);)",
    lambda m: '\n'.join('// ' + line for line in m.group(1).split('\n')),
    content, flags=re.DOTALL
)

# Insert dynamic loader before the now-commented StatusView block
loader = (
    "// Load custom PVE.node.StatusView from external module\n"
    "Ext.Loader.loadScript({\n"
    "    url: '/pve2/js/PveMod_PveNodeStatusView.js',\n"
    "    onLoad: function() { },\n"
    "    onError: function() { console.error('Failed to load PveMod_PveNodeStatusView.js'); }\n"
    "});\n"
)
content = re.sub(
    r"(// Ext\.define\('PVE\.node\.StatusView',)",
    loader + r'\1',
    content, count=1
)
open(path, 'w').write(content)
PYEOF
        info "Patched pvemanagerlib.js"
        CHANGED=true
    fi
fi

# ── node-info: GPU RRD history ────────────────────────────────────────────────
if [[ "$NODE_INFO" == "1" && "$GPU_HISTORY" == "1" ]]; then
    if ! grep -qF "gpurrddata" "$NODES_PM" 2>/dev/null; then
        # Register method in the node sub-path list
        sed -i "s/{ name => 'rrddata' },/{ name => 'rrddata' },\n            { name => 'gpurrddata' },/" "$NODES_PM"

        # Append gpurrddata method definition after the rrddata code block
        python3 - "$NODES_PM" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'gpurrddata' in content:
    sys.exit(0)

method = r"""
__PACKAGE__->register_method({
    name => 'gpurrddata',
    path => 'gpurrddata',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    description => "Read GPU RRD statistics",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            card => {
                description => "The GPU card identifier (e.g. card0, nvidia0).",
                type => 'string',
                pattern => '[a-zA-Z0-9]+',
            },
            timeframe => {
                description => "Specify the time frame you are interested in.",
                type => 'string',
                enum => ['hour', 'day', 'week', 'month', 'year', 'decade'],
            },
            cf => {
                description => "The RRD consolidation function",
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
            },
        },
    },
    returns => {
        type => "array",
        items => {
            type => "object",
            properties => {},
        },
    },
    code => sub {
        my ($param) = @_;
        my $nodename = PVE::INotify::nodename();
        my $card = $param->{card};
        die "invalid card name\n" unless $card =~ /^[a-zA-Z0-9]+$/;
        return PVE::RRD::create_rrd_data(
            "pve-mod-gpu/$nodename/$card", $param->{timeframe}, $param->{cf},
        );
    },
});
"""

# Insert before the final 1; at end of file
content = re.sub(r'\n1;\s*$', method + '\n1;\n', content)
open(path, 'w').write(content)
PYEOF

        mkdir -p "$GPU_RRD_DIR"
        chown www-data:www-data "$GPU_RRD_DIR" 2>/dev/null || true
        info "Installed gpurrddata API endpoint"
        CHANGED=true
    fi
fi

# ── migrate-storage: pvemanagerlib.js ─────────────────────────────────────────
# The stock VM migrate dialog only offers a "Target storage" selector for
# *running* VMs (live storage migration). For powered-off VMs it is hidden and
# the 'targetstorage' parameter is never sent, even though the migrate API and
# `qm migrate --targetstorage` fully support offline storage relocation. This
# patch drops the `&& running` guard in two spots so the selector also appears
# for offline VMs and the parameter is forwarded, and skips a third spot (the
# offline allowed-nodes/storage precondition) that would otherwise restrict the
# target node and block Migrate when the current storage is absent on the target.
#
# No file backup is taken on purpose: the edit is a surgical, fully reversible
# regex (see revert-patches.sh) keyed on the 'pve-mod-offline-storage' marker.
# This avoids colliding with the node-info backup of the same file, whose
# revert restores the newest pvemanagerlib.js.* backup.
if [[ "$MIGRATE_STORAGE" == "1" ]]; then
    if ! grep -qF "pve-mod-offline-storage" "$PVE_MANAGER_JS" 2>/dev/null; then
        python3 - "$PVE_MANAGER_JS" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'pve-mod-offline-storage' in content:
    sys.exit(0)

# 1. setStorageselectorHidden formula: show selector regardless of run state.
#    get('migration.with-local-disks') && get('running')
sel_re = re.compile(
    r"get\(\s*['\"]migration\.with-local-disks['\"]\s*\)\s*&&\s*"
    r"get\(\s*['\"]running['\"]\s*\)"
)
content, n_sel = sel_re.subn(
    "get('migration.with-local-disks') && true /* pve-mod-offline-storage-selector */",
    content, count=1,
)
if n_sel != 1:
    print("ERROR: setStorageselectorHidden anchor not found in pvemanagerlib.js",
          file=sys.stderr)
    sys.exit(1)

# 2. startMigration: forward 'targetstorage' for offline VMs too.
#    vm.get('migration.with-local-disks') && vm.get('running') && values.targetstorage
sub_re = re.compile(
    r"vm\.get\(\s*['\"]migration\.with-local-disks['\"]\s*\)\s*&&\s*"
    r"vm\.get\(\s*['\"]running['\"]\s*\)\s*&&\s*values\.targetstorage"
)
content, n_sub = sub_re.subn(
    "vm.get('migration.with-local-disks') && true "
    "/* pve-mod-offline-storage-submit */ && values.targetstorage",
    content, count=1,
)
if n_sub != 1:
    print("ERROR: startMigration targetstorage anchor not found in pvemanagerlib.js",
          file=sys.stderr)
    sys.exit(1)

# 3. checkQemuPreconditions: skip the offline allowed-nodes / storage block.
#    For offline VMs this block (a) sets migration.allowedNodes, which restricts
#    the Target node selector to nodes already hosting the VM's current storage
#    (so the chosen node shows "Node X is not allowed for this action"), and
#    (b) pushes a blocking "Storage(s) not available on target" error that
#    disables Migrate. Both are exactly what target-storage relocation resolves,
#    so short-circuit the outer guard: migration.allowedNodes stays undefined
#    (its default → no node restriction) and the blocking error is never raised.
#    Unrelated checks (mapped resources, HA, local passthrough) are untouched.
#    if (migrateStats.allowed_nodes && !vm.get('running')) {
precond_re = re.compile(
    r"(if\s*\(\s*)"
    r"(migrateStats\.allowed_nodes\s*&&\s*!\s*vm\.get\(\s*['\"]running['\"]\s*\))"
    r"(\s*\)\s*\{)"
)
content, n_pre = precond_re.subn(
    r"\1false /* pve-mod-offline-storage-precond */ && \2\3",
    content, count=1,
)
if n_pre != 1:
    print("ERROR: offline allowed_nodes precondition anchor not found in pvemanagerlib.js",
          file=sys.stderr)
    sys.exit(1)

open(path, 'w').write(content)
PYEOF
        info "Patched pvemanagerlib.js (offline VM target storage selector)"
        CHANGED=true
    fi
fi

# ── nag-screen: proxmoxlib.js ─────────────────────────────────────────────────
if [[ "$NAG_SCREEN" == "1" ]]; then
    if ! grep -qF "// disable subscription nag screen" "$PROXMOXLIB_JS" 2>/dev/null; then
        backup_file "$PROXMOXLIB_JS"
        python3 - "$PROXMOXLIB_JS" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if '// disable subscription nag screen' in content:
    sys.exit(0)

m = re.search(r'(checked_command:\s*function\s*\(orig_cmd\)\s*\{)', content)
if not m:
    print("ERROR: checked_command pattern not found in proxmoxlib.js", file=sys.stderr)
    sys.exit(1)

insert = "\n\t\t\t// disable subscription nag screen\n\t\t\torig_cmd();\n\t\t\treturn;"
pos = m.end()
content = content[:pos] + insert + content[pos:]
open(path, 'w').write(content)
PYEOF
        info "Patched proxmoxlib.js (nag screen)"
        CHANGED=true
    fi

    if [[ ! -L "$PROXMOXLIB_MIN_JS" ]]; then
        backup_file "$PROXMOXLIB_MIN_JS"
        mv "$PROXMOXLIB_MIN_JS" "$BACKUP_DIR/proxmoxlib.min.js.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        ln -sf "$PROXMOXLIB_JS" "$PROXMOXLIB_MIN_JS"
        info "Symlinked proxmoxlib.min.js → proxmoxlib.js"
        CHANGED=true
    fi
fi

# ── restart pveproxy if anything changed ──────────────────────────────────────
if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    systemctl restart pveproxy 2>/dev/null || true
fi
