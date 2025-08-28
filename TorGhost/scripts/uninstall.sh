#!/usr/bin/env bash
set -Eeuo pipefail
say(){ printf "%b\n" "$*"; }

[[ $EUID -eq 0 ]] || { say "\n[!] Run as root (sudo).\n"; exit 1; }

say "\n[i] Stopping TorGhost (if active)..."
if command -v torghost >/dev/null 2>&1; then
  torghost stop || true
fi

say "[i] Removing /usr/local/sbin/torghost"
rm -f /usr/local/sbin/torghost || true

say "[i] Restoring resolver (if drop-in exists)"
if [[ -f /etc/systemd/resolved.conf.d/torghost.conf ]]; then
  rm -f /etc/systemd/resolved.conf.d/torghost.conf
  systemctl restart systemd-resolved || true
fi
if [[ -f /var/lib/torghost/resolv.conf.backup ]]; then
  cp -a /var/lib/torghost/resolv.conf.backup /etc/resolv.conf || true
  rm -f /var/lib/torghost/resolv.conf.backup || true
fi

say "[i] Removing nftables table if present"
nft list table inet tor_anon >/dev/null 2>&1 && nft delete table inet tor_anon || true

say "[i] Deleting saved nftables backup"
rm -f /var/lib/torghost/nftables.rules.backup || true

say "[i] Leaving /etc/default/torghost.conf and torrc as-is (manual cleanup if desired)."

say "\n[✓] Uninstall complete."
