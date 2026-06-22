#!/usr/bin/env bash
# Configure the macOS Thunderbolt Bridge for a direct, point-to-point link
# between the two Mac Studios so llama.cpp RPC (GLM-5.2) rides Thunderbolt 5
# instead of the LAN. Run once on each host after connecting the TB5 cable.
#
#   scripts/tb5_bridge_setup.sh main      # faepmac1 -> 10.78.5.1
#   scripts/tb5_bridge_setup.sh worker    # faepmac2 -> 10.78.5.2
#   scripts/tb5_bridge_setup.sh 10.78.5.7 # explicit address
#
# Uses a /24 distinct from the WireGuard mesh (10.77.0.0/24) so cluster traffic
# is unambiguous. No default route is set: this is an isolated 2-host segment,
# not an uplink. macOS auto-creates the "Thunderbolt Bridge" service (bridge0)
# spanning every Thunderbolt port, so the same cable works on any TB port.
#
# Needs sudo (networksetup mutates system network config). Idempotent.
#
# Env:
#   TB5_SUBNET   first three octets (default 10.78.5)
#   TB5_MASK     netmask (default 255.255.255.0)
#   TB5_MTU      set a jumbo MTU on bridge0 for bulk throughput (e.g. 9000);
#                non-persistent across reboot, re-run to reapply (default: unset)
#   TB5_SERVICE  network service name (default "Thunderbolt Bridge")
#   TB5_DRY_RUN  true to print the planned address/commands and exit (no sudo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "Thunderbolt Bridge setup is macOS-only"
[[ $# -eq 1 ]] || die "usage: $0 <main|worker|IPv4>"

SUBNET="${TB5_SUBNET:-10.78.5}"
MASK="${TB5_MASK:-255.255.255.0}"
SERVICE="${TB5_SERVICE:-Thunderbolt Bridge}"

case "$1" in
  main)   IP="${SUBNET}.1"; PEER="${SUBNET}.2" ;;
  worker) IP="${SUBNET}.2"; PEER="${SUBNET}.1" ;;
  *.*.*.*) IP="$1"; PEER="" ;;
  *) die "role must be main, worker, or an IPv4 address" ;;
esac

if [[ "${TB5_DRY_RUN:-false}" == "true" ]]; then
  echo "networksetup -setmanual ${SERVICE} ${IP} ${MASK} (empty router)"
  [[ -n "${TB5_MTU:-}" ]] && echo "ifconfig bridge0 mtu ${TB5_MTU}"
  echo "- ip:   ${IP}"
  [[ -n "${PEER}" ]] && echo "- peer: ${PEER}"
  exit 0
fi

have networksetup || die "networksetup not found"
networksetup -listallnetworkservices 2>/dev/null | grep -qx "${SERVICE}" \
  || die "network service '${SERVICE}' not found. Connect the Thunderbolt-5 cable between the two Macs first (macOS creates it automatically)."

echo "configuring '${SERVICE}' -> ${IP}/${MASK} (sudo)"
# Empty router: point-to-point segment, no uplink/default route.
sudo networksetup -setmanual "${SERVICE}" "${IP}" "${MASK}" ""

if [[ -n "${TB5_MTU:-}" ]]; then
  echo "setting bridge0 MTU ${TB5_MTU} (non-persistent)"
  sudo ifconfig bridge0 mtu "${TB5_MTU}" || warn "could not set MTU ${TB5_MTU} (interface may not support it)"
fi

echo "- assigned: $(ipconfig getifaddr bridge0 2>/dev/null || echo '(pending)')"
if [[ -n "${PEER}" ]]; then
  echo "- peer:     ${PEER}"
  if ping -c 2 -t 3 "${PEER}" >/dev/null 2>&1; then
    echo "- peer reachable over the bridge"
  else
    echo "- peer not yet reachable (configure the other Mac, or check the cable)"
  fi
fi
