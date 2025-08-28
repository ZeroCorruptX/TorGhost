#!/usr/bin/env bash
# torghost — modern Tor transparent routing for Kali/Debian (systemd + nftables)
# Features: nftables NAT to Tor TransPort/DNSPort, systemd-resolved drop-in,
# IPv6 leak avoidance, MAC & hostname randomization, optional BleachBit cleanup.

set -Eeuo pipefail

# ----- Defaults (overridden by /etc/default/torghost.conf) -----
DEFAULTS="/etc/default/torghost.conf"
NON_TOR="192.168.0.0/16 172.16.0.0/12 10.0.0.0/8"
TO_KILL="chrome chromium firefox brave opera vivaldi skype thunderbird signal discord slack teams dropbox telegram-desktop pidgin xchat"
BLEACHBIT_CLEANERS="bash.history system.cache system.clipboard system.custom system.recent_documents system.rotated_logs system.tmp system.trash"
OVERWRITE="false"
REAL_HOSTNAME="kali"
CHANGE_MAC="true"
RANDOM_HOSTNAME="true"
PARANOID_MODE="false"

# Tor ports (torrc must match these)
TRANS_PORT="9040"
DNS_PORT="9053"

# nftables table/chain names
NFT_TABLE="inet tor_anon"
NFT_NAT_CH="nat_output"
NFT_FIL_CH="filter_output"

# State
STATE_DIR="/var/lib/torghost"
mkdir -p "$STATE_DIR"
NFT_BACKUP="$STATE_DIR/nftables.rules.backup"
HOSTNAME_BAK="$STATE_DIR/hostname.backup"
RESOLV_BAK="$STATE_DIR/resolv.conf.backup"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN="$RESOLVED_DROPIN_DIR/torghost.conf"
IPV6_BAK="$STATE_DIR/ipv6.disabled.backup"

# ----- Helpers -----
log(){ echo -e "$*"; }
need_root(){ [[ $EUID -eq 0 ]] || { log "\n[!] Run as root (sudo)\n"; exit 1; }; }
load_defaults(){ [[ -f "$DEFAULTS" ]] && . "$DEFAULTS" || true; }
has(){ command -v "$1" >/dev/null 2>&1; }

tor_uid(){
  local uid=""
  if id -u debian-tor >/dev/null 2>&1; then uid="$(id -u debian-tor)"; fi
  if [[ -z "$uid" ]] && id -u tor >/dev/null 2>&1; then uid="$(id -u tor)"; fi
  if [[ -z "$uid" ]]; then
    uid="$(ps -C tor -o uid= 2>/dev/null | head -n1 | tr -d ' ')"
  fi
  echo "${uid:-0}"
}

rand_word(){
  local W="/usr/share/dict/words"
  [[ -f "$W" ]] && shuf -n1 "$W" | tr -cd '[:alpha:]' | tr '[:upper:]' '[:lower:]' || echo "cloud$RANDOM"
}

interfaces(){
  ls /sys/class/net | grep -Ev '^(lo|docker.*|veth.*|br-.*|virbr.*|tun.*|tap.*|wg.*)$' || true
}

is_vm(){ has virt-what && [[ -n "$(virt-what || true)" ]]; }

kill_leaky_apps(){
  local list=($TO_KILL)
  [[ ${#list[@]} -gt 0 ]] && killall -q "${list[@]}" 2>/dev/null || true
  log " * Killed common leak-prone apps (browsers/messengers)"
}

mac_randomize(){
  local mode="$1"  # random|permanent
  if is_vm; then log " * VM detected: skipping MAC change"; return 0; fi
  has macchanger || { log " * macchanger not installed; skipping MAC change"; return 0; }
  local ifs; ifs="$(interfaces || true)"
  [[ -z "$ifs" ]] && { log " * No eligible interfaces found"; return 0; }
  while read -r IFACE; do
    [[ -z "$IFACE" ]] && continue
    ip link set "$IFACE" down || true
    if [[ "$mode" == "random" ]]; then macchanger -r "$IFACE" >/dev/null 2>&1
    else macchanger -p "$IFACE" >/dev/null 2>&1
    fi
    ip link set "$IFACE" up || true
    macchanger -s "$IFACE" 2>/dev/null | sed 's/^/   - /'
  done <<< "$ifs"
}

hostname_change(){
  [[ -f "$HOSTNAME_BAK" ]] || echo "$(hostnamectl --static 2>/dev/null || hostname)" > "$HOSTNAME_BAK"
  local new="$1"
  hostnamectl set-hostname "$new" 2>/dev/null || { echo "$new" > /etc/hostname; sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$new/g" /etc/hosts || true; }
  log " * Hostname changed to: $new"
}
hostname_restore(){
  if [[ -f "$HOSTNAME_BAK" ]]; then
    hostname_change "$(cat "$HOSTNAME_BAK")"; rm -f "$HOSTNAME_BAK"
  else
    hostname_change "$REAL_HOSTNAME"
  fi
}

resolved_prepare(){
  mkdir -p "$RESOLVED_DROPIN_DIR"
  cat > "$RESOLVED_DROPIN" <<EOF
[Resolve]
DNS=127.0.0.1
Domains=~.
EOF
  systemctl restart systemd-resolved || true
  log " * systemd-resolved configured (DNS -> 127.0.0.1)"
}
resolved_restore(){
  [[ -f "$RESOLVED_DROPIN" ]] && rm -f "$RESOLVED_DROPIN" && systemctl restart systemd-resolved || true
  log " * systemd-resolved restored"
}
resolvconf_prepare_fallback(){
  if [[ ! -L /etc/resolv.conf ]]; then
    [[ -f "$RESOLV_BAK" ]] || cp -a /etc/resolv.conf "$RESOLV_BAK"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    log " * /etc/resolv.conf -> 127.0.0.1"
  fi
}
resolvconf_restore_fallback(){
  [[ -f "$RESOLV_BAK" ]] && cp -a "$RESOLV_BAK" /etc/resolv.conf && rm -f "$RESOLV_BAK" && log " * /etc/resolv.conf restored"
}

ipv6_disable_temporarily(){
  [[ -f "$IPV6_BAK" ]] || (sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}' > "$IPV6_BAK" || echo "0" > "$IPV6_BAK")
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  log " * IPv6 disabled temporarily"
}
ipv6_restore(){
  [[ -f "$IPV6_BAK" ]] && sysctl -w net.ipv6.conf.all.disable_ipv6="$(cat "$IPV6_BAK")" >/dev/null 2>&1 || true
  rm -f "$IPV6_BAK" || true
  log " * IPv6 setting restored"
}

nft_save_rules(){ nft list ruleset > "$NFT_BACKUP" 2>/dev/null || true; }
nft_restore_rules(){ [[ -f "$NFT_BACKUP" ]] && nft -f "$NFT_BACKUP" 2>/dev/null || true; rm -f "$NFT_BACKUP" || true; log " * nftables rules restored"; }
nft_flush_tor_table(){ nft list table $NFT_TABLE >/dev/null 2>&1 && nft delete table $NFT_TABLE || true; }
nft_setup_tor(){
  local UID; UID="$(tor_uid)"
  if [[ "$UID" -eq 0 ]]; then
    log "\n[!] Tor UID not found; starting tor..."
    systemctl start tor || true
    UID="$(tor_uid)"; [[ "$UID" -eq 0 ]] && { log "[!] Tor not running; abort."; exit 1; }
  fi
  nft add table $NFT_TABLE
  nft add chain $NFT_TABLE $NFT_NAT_CH '{ type nat hook output priority -100 ; }'
  nft add chain $NFT_TABLE $NFT_FIL_CH '{ type filter hook output 0 ; }'
  nft add rule $NFT_TABLE $NFT_NAT_CH meta skuid $UID return
  nft add rule $NFT_TABLE $NFT_NAT_CH udp dport 53 redirect to $DNS_PORT
  nft add rule $NFT_TABLE $NFT_NAT_CH tcp flags syn / syn redirect to $TRANS_PORT
  nft add rule $NFT_TABLE $NFT_FIL_CH ct state established,related accept
  nft add rule $NFT_TABLE $NFT_FIL_CH ip daddr 127.0.0.0/8 accept
  nft add rule $NFT_TABLE $NFT_FIL_CH meta skuid $UID accept
  if [[ "${PARANOID_MODE}" != "true" ]]; then
    for NET in $NON_TOR; do
      nft add rule $NFT_TABLE $NFT_FIL_CH ip daddr $NET accept
      nft add rule $NFT_TABLE $NFT_NAT_CH ip daddr $NET return
    done
  fi
  nft add rule $NFT_TABLE $NFT_FIL_CH meta nfproto ipv6 drop
  nft add rule $NFT_TABLE $NFT_FIL_CH reject with icmpx type admin-prohibited
  log " * nftables Tor redirect loaded (tor uid: $UID)"
}

bleachbit_clean(){
  has bleachbit || return 0
  [[ "${OVERWRITE}" == "true" ]] && bleachbit -o -c $BLEACHBIT_CLEANERS >/dev/null 2>&1 || bleachbit -c $BLEACHBIT_CLEANERS >/dev/null 2>&1
  log " * BleachBit cleanup done"
}

tor_check_or_start(){ systemctl is-active --quiet tor || systemctl start tor || true; }

status_check(){
  log "\n[i] TorGhost status"
  ip -o link show | awk -F': ' '{print " * IFACE: " $2}'
  log " * Hostname: $(hostname)"
  local RESP IP OK
  RESP="$(curl -s --max-time 12 https://check.torproject.org/api/ip || true)"
  IP="$(echo "$RESP" | sed -n 's/.*"IP":"\([^"]*\)".*/\1/p')"
  OK="$(echo "$RESP" | sed -n 's/.*"IsTor":\([^,}]*\).*/\1/p')"
  if [[ "$OK" == "true" ]]; then
    log " * Exit IP: $IP"
    log " * Tor ON\n"
  else
    log " * IP: ${IP:-unknown}"
    log " * Tor may be OFF (or check failed)\n"
    exit 3
  fi
}

start_mode(){
  need_root; load_defaults
  log "\n[i] Starting TorGhost (remember: logins/cookies/JS can reveal you)"
  if systemctl is-active --quiet systemd-resolved; then resolved_prepare; else resolvconf_prepare_fallback; fi
  kill_leaky_apps
  [[ "${CHANGE_MAC}" == "true" ]] && mac_randomize "random"
  [[ "${RANDOM_HOSTNAME}" == "true" ]] && hostname_change "$(rand_word)"
  tor_check_or_start
  nft_save_rules
  ipv6_disable_temporarily
  nft_flush_tor_table
  nft_setup_tor
  log " * TorGhost ACTIVE"
}

stop_mode(){
  need_root; load_defaults
  log "\n[i] Stopping TorGhost"
  nft_flush_tor_table
  nft_restore_rules
  if systemctl is-active --quiet systemd-resolved; then resolved_restore; else resolvconf_restore_fallback; fi
  kill_leaky_apps
  [[ "${CHANGE_MAC}" == "true" ]] && mac_randomize "permanent"
  hostname_restore
  ipv6_restore
  [[ -n "${DISPLAY:-}" ]] && bleachbit_clean
  log " * TorGhost OFF\n"
}

update_note(){ log "\n[i] No auto-update; review and replace this file manually if needed."; }
usage(){ echo "Usage: sudo torghost {start|stop|status|update}"; exit 3; }

case "${1:-}" in
  start)  start_mode ;;
  stop)   stop_mode ;;
  status) status_check ;;
  update) update_note ;;
  *)      usage ;;
esac
