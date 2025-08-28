# TorGhost 👻

**Surf the net like a ghost — route all your traffic through Tor with one command.**

TorGhost sets up **transparent Tor routing** on modern Kali/Debian (systemd + nftables), blocks common leaks, and can randomize your **MAC** and **hostname**. It’s built for labs and education.

> ⚠️ Your behavior still matters. Logins, cookies, and JavaScript can deanonymize you. Use responsibly in controlled environments.

---

## ✨ Features
- One command UX: `sudo torghost start | status | stop`
- Transparent routing via **nftables**
- **systemd-resolved** aware DNS handling
- Blocks IPv6 & DNS leaks
- Optional **MAC** and **hostname** randomization
- **Paranoid Mode**: force *everything* (even LAN) through Tor
- BleachBit cleanup option when stopping (if GUI)

---

## 🚀 Quick Start
```bash
# 1) Install (as root)
sudo bash scripts/install.sh

# 2) Use it
sudo torghost start
sudo torghost status
sudo torghost stop
