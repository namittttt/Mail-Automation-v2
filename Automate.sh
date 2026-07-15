#!/bin/bash
set -e

echo "========================================"
echo " Mail Server — Full Automated Build"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─────────────────────────────────────────────
# Steps that build the base server, run once (or
# safely re-run — every script here is idempotent).
# ─────────────────────────────────────────────
STEPS=(
    "01-install.sh"
    "02A-configure.sh"
    "03A-postfix.sh"
    "04A-dovecot.sh"
    "05B-roundcube.sh"
    "10B-Rspamd.sh"
    "12B-Security.sh"

)

# ─────────────────────────────────────────────
# Preflight: make sure every script we're about to run
# actually exists BEFORE starting, so we don't fail
# halfway through a partially-completed build.
# ─────────────────────────────────────────────
echo
echo "Checking all required scripts are present..."
MISSING=0
for step in "${STEPS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$step" ]; then
        echo "  MISSING: $step"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo
    echo "ERROR: one or more required scripts are missing from $SCRIPT_DIR"
    echo "Fix the file names above (check for typos or stale duplicates"
    echo "like 12A-security.sh vs 12B-Security.sh) before running this again."
    exit 1
fi

# qmail-schema.ldif is a hard dependency of 02-configure.sh's schema
# loading step and 07-groups.sh's qmailGroup usage -- check it too.
if [ ! -f "$SCRIPT_DIR/qmail-schema.ldif" ]; then
    echo "  MISSING: qmail-schema.ldif (needed by 02-configure.sh)"
    exit 1
fi

echo "All required files present."
echo

# ─────────────────────────────────────────────
# Run each step in order. Stop immediately on the
# first failure -- every later step depends on
# earlier ones succeeding (e.g. Postfix config
# needs LDAP already set up), so continuing past
# a failure would just cascade confusing errors.
# ─────────────────────────────────────────────
chmod +x "${STEPS[@]}"

for step in "${STEPS[@]}"; do
    echo
    echo "════════════════════════════════════════"
    echo " Running: $step"
    echo "════════════════════════════════════════"

    if ! "./$step"; then
        echo
        echo "════════════════════════════════════════"
        echo " FAILED at: $step"
        echo "════════════════════════════════════════"
        echo
        echo "Scroll up to see $step's actual error output above."
        echo "Fix that issue, then just re-run this script --"
        echo "every step here is safe to re-run from the top."
        exit 1
    fi

    echo
    echo "✓ $step completed successfully."
done

echo
echo "========================================"
echo " Full Build Complete"
echo "========================================"
echo
echo "Base server is up: LDAP, Postfix, Dovecot, Roundcube,"
echo "Rspamd, ClamAV, Fail2ban."
echo
echo "NOT run automatically (these are per-user/per-group admin"
echo "actions, not part of the base build -- run them yourself"
echo "whenever you need to add a user or group):"
echo "  ./06-create-user.sh"
echo "  ./07-groups.sh"
echo
echo "Verify everything is actually healthy:"
echo "  systemctl status slapd mariadb postfix nginx dovecot redis-server rspamd clamav-daemon fail2ban"
