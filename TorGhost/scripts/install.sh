#!/usr/bin/env bash
set -Eeuo pipefail

ts(){ date +"%Y%m%d-%H%M%S"; }
backup(){ [[ -f "$1" ]] && cp -a "$1" "$1.$(ts).bak" || true; }
say(){ printf "%b\n" "$*"; }

[[ $EUID -eq 0 ]] || { say "\n[!] Run as root (sudo).\n"; exit 1; }

say "\n[i] Installing required packages..."
apt update -y
apt install -y tor macchanger bleachbit curl nftables systemd-timesyncd

say "[i] Enabling nftables..."
systemctl enable nftables >/dev/null 2>&1 || true
systemctl start nftables  >/dev/null 2>&1 || true

# install main binary
say "[i] Installing /usr/local/sbin/torghost"
install -m 0755 -D "$(dirname "$0")/../bin/torghost" /usr/local/sbin/torghost

# install defaults
say "[i] Installing /etc/default/torghost.conf"
backup /etc/default/torghost.conf
install -m 0644 -D "$(dirname "$0")/../config/torghost.conf" /etc/default/torghost.conf

# configure tor
say "[i] Configuring /etc/tor/torrc"
backup /etc/tor/torrc
sed -i '/# BEGIN torghost-managed/,/# END torghost-managed/d' /etc/tor/torrc || true
cat >> /etc/tor/torrc <<'EOF_TOR'

# BEGIN torghost-managed
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 9053
# END torghost-managed
EOF_TOR
systemctl enable tor >/dev/null 2>&1 || true
systemctl restart tor || true

# clean old iptables artifacts (safe if empty)
say "[i] Cleaning any old iptables rules"
iptables -F || true
iptables -t nat -F || true
[[ -f /etc/network/iptables.rules ]] && rm -f /etc/network/iptables.rules || true

say "\n[✓] Install complete.\nTry:\n  sudo torghost start\n  sudo torghost status\n  sudo torghost stop\n"
