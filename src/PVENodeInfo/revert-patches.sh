#!/usr/bin/env bash
# /usr/lib/pve-mod/revert-patches.sh
#
# Reverts all patches applied by apply-patches.sh.
# Restores PVE system files from backups in /var/lib/pve-mod/backup/.
# Called by prerm before package files are removed.

BACKUP_DIR="/var/lib/pve-mod/backup"
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PVE_MOD_JS="/usr/share/pve-manager/js/PveMod_PveNodeStatusView.js"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PROXMOXLIB_MIN_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"

info() { echo "[pve-mod] $*"; }
warn() { echo "[pve-mod] WARNING: $*" >&2; }

restore_latest() {
    local name="$1" target="$2"
    local latest
    latest=$(find "$BACKUP_DIR" -name "${name}.*" -type f -printf '%T+ %p\n' 2>/dev/null \
        | sort -r | head -n1 | awk '{print $2}')
    if [[ -n "$latest" ]]; then
        cp "$latest" "$target"
        info "Restored $(basename "$target") from backup"
    else
        warn "No backup found for ${name}; $target not restored"
    fi
}

CHANGED=false

# ── node-info: Nodes.pm ───────────────────────────────────────────────────────
if grep -qF "use PVE::API2::PVEMod_SensorInfo" "$NODES_PM" 2>/dev/null; then
    restore_latest "Nodes.pm" "$NODES_PM"
    CHANGED=true
fi

# ── node-info: pvemanagerlib.js ───────────────────────────────────────────────
if grep -qF "PveMod_PveNodeStatusView.js" "$PVE_MANAGER_JS" 2>/dev/null; then
    restore_latest "pvemanagerlib.js" "$PVE_MANAGER_JS"
    CHANGED=true
fi

# ── migrate-storage: pvemanagerlib.js ─────────────────────────────────────────
# Reverse the surgical edit from apply-patches.sh, restoring the original
# `&& running` guards. Run AFTER the node-info restore above: if node-info was
# enabled after migrate-storage, its pvemanagerlib.js backup already contains
# the migrate markers, so restoring it reintroduces them — reverting here, last,
# strips them in every ordering and leaves the file pristine.
if grep -qF "pve-mod-offline-storage" "$PVE_MANAGER_JS" 2>/dev/null; then
    python3 - "$PVE_MANAGER_JS" <<'PYEOF'
import sys

path = sys.argv[1]
content = open(path).read()

# Reverse the startMigration edit first (more specific), then the selector one.
content = content.replace(
    "vm.get('migration.with-local-disks') && true "
    "/* pve-mod-offline-storage-submit */ && values.targetstorage",
    "vm.get('migration.with-local-disks') && vm.get('running') && values.targetstorage",
)
content = content.replace(
    "get('migration.with-local-disks') && true /* pve-mod-offline-storage-selector */",
    "get('migration.with-local-disks') && get('running')",
)
# Strip the precondition short-circuit, restoring the original guard verbatim.
content = content.replace(
    "false /* pve-mod-offline-storage-precond */ && ",
    "",
)
open(path, 'w').write(content)
PYEOF
    info "Reverted pvemanagerlib.js (offline VM target storage selector)"
    CHANGED=true
fi

# ── node-info: JS module file ─────────────────────────────────────────────────
if [[ -f "$PVE_MOD_JS" ]]; then
    rm -f "$PVE_MOD_JS"
    info "Removed PveMod_PveNodeStatusView.js"
    CHANGED=true
fi

# ── nag-screen: proxmoxlib.min.js symlink ────────────────────────────────────
if [[ -L "$PROXMOXLIB_MIN_JS" ]]; then
    rm -f "$PROXMOXLIB_MIN_JS"
    restore_latest "proxmoxlib.min.js" "$PROXMOXLIB_MIN_JS"
    CHANGED=true
fi

# ── nag-screen: proxmoxlib.js ────────────────────────────────────────────────
if grep -qF "// disable subscription nag screen" "$PROXMOXLIB_JS" 2>/dev/null; then
    restore_latest "proxmoxlib.js" "$PROXMOXLIB_JS"
    CHANGED=true
fi

# ── restart pveproxy if anything changed ─────────────────────────────────────
if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    systemctl restart pveproxy 2>/dev/null || true
fi
