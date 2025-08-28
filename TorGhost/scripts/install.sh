#!/usr/bin/env bash
# TorGhost installer (Kali/Debian). LF-only, CRLF-safe, systemd + nftables.
set -Eeuo pipefail

say(){ printf "%b\n" "$*"; }
ts(){ date +"%Y%m%d-%H%M%S"; }
backup(){ [[ -f "$1" ]] && cp -a "$1" "$1.$(ts).bak" || true; }

# Strip CR (\r) if present (handles files saved with Windows CRLF)
strip_cr(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  # in-place, portable CR removal
  sed -i 's/\r$//' "$f"
}

require_root(){
  if [[ $EUID -ne 0 ]]; then
    say "\n[!] Run as root (try: sudo ./scripts/install.sh)\n"
    exit 1
  fi
}

main() {
  require_root

  say "\n[i] Preparing files (normalizing line endings)…"
  # Normalize local sources before install (prevents bash\r issues)
  strip_cr "$(dirname "$0")/install.sh"
  strip_cr "$(dirname "$0")/uninstall.sh"
  strip_cr "$(dirname "$0")/../bin/torghost"
  strip_cr "$(dirname "$0")/../config/torghost.conf"

  say "[i] Installing required packages…"
  apt update -y
  # Keep list minimal/available on Kali/Debian
  apt install -y tor macchanger bleachbit curl nftables systemd-timesyncd || true

  say "[i] Enabling nftables…"
  systemctl enable nftables >/dev/null 2>&1 || true
  systemctl start nftables  >/dev/null 2>&1 || true

  say "[i] Installing /usr/local/sbin/torghost"
  install -m 0755 -D "$(dirname "$0")/../bin/torghost" /usr/local/sbin/torghost

  say "[i] Installing /etc/default/torghost.conf"
  backup /etc/default/torghost.conf
  install -m 0644 -D "$(dirname "$0")/../config/torghost.conf" /etc/default/torghost.conf

  say "[i] Configuring /etc/tor/torrc (idempotent block)…"
  backup /etc/tor/torrc
  # Remove any previous managed block
  sed -i '/# BEGIN torghost-managed/,/# END torghost-managed/d' /etc/tor/torrc || true
  # Append our managed block once
  cat >> /etc/tor/torrc <<'EOF_TOR'

# BEGIN torghost-managed
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 9053
# END torghost-managed
EOF_TOR

  say "[i] Enabling + restarting tor…"
  systemctl enable tor >/dev/null 2>&1 || true
  systemctl restart tor || true

  say "[i] Cleaning any old iptables rules (safe if empty)…"
  iptables -F || true
  iptables -t nat -F || true
  [[ -f /etc/network/iptables.rules ]] && rm -f /etc/network/iptables.rules || true

  say "\n[✓] Install complete."
  say "Try:\n  sudo torghost start\n  sudo torghost status\n  sudo torghost stop\n"
}

main "$@"
