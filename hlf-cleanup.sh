#!/usr/bin/env bash
# =============================================================================
# HLF Cleanup Script - Remove all HLF resources for a fresh install
# Reads config.yaml to determine what to delete (same config as hlf-deploy.sh)
#
# Usage:  ./hlf-cleanup.sh [config.yaml] [--skip-confirm] [--keep-namespaces]
# =============================================================================
set -euo pipefail

CONFIG="${1:-config.yaml}"
SKIP_CONFIRM=false
KEEP_NAMESPACES=false

for arg in "$@"; do
  case "$arg" in
    --skip-confirm)    SKIP_CONFIRM=true ;;
    --keep-namespaces) KEEP_NAMESPACES=true ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file '$CONFIG' not found"; exit 1
fi

for cmd in kubectl yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not found in PATH"; exit 1
  fi
done

log()     { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }
confirm() {
  if $SKIP_CONFIRM; then return 0; fi
  local q="$1"
  read -r -p "$q [y/N]: " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

y() { yq eval "$1" "$CONFIG"; }

org_field() {
  local name="$1" field="$2"
  yq eval ".orgs[] | select(.name == \"$name\") | .$field" "$CONFIG"
}

# --- Read config ---
ORD_NS=$(y '.orderer.namespace')
ORD_CA=$(y '.orderer.ca_name')
ORD_COUNT=$(y '.orderer.count')
ORG_COUNT=$(y '.orgs | length')
CHANNEL_COUNT=$(y '.channels | length')
CC_COUNT=$(y '.chaincodes | length')

log "========================================="
log "HLF CLEANUP - This will DELETE all HLF resources!"
log "Config: $CONFIG"
log "========================================="

if ! confirm "Are you sure you want to delete ALL HLF resources?"; then
  echo "Aborted."; exit 0
fi

# ==========================================================================
# 1. Delete CCAAS deployments (chaincode containers)
# ==========================================================================
log "===== Deleting CCAAS deployments ====="

# Collect unique {cc_name, org_ns} pairs
declare -A SEEN_CCAAS
for (( cci=0; cci<CC_COUNT; cci++ )); do
  CC_NAME=$(y ".chaincodes[$cci].name")
  CC_ORG_COUNT=$(y ".chaincodes[$cci].orgs | length")
  CC_CHANNEL_COUNT=$(y ".chaincodes[$cci].channels | length")

  # Collect all active orgs (intersection of cc orgs and channel orgs)
  for (( j=0; j<CC_CHANNEL_COUNT; j++ )); do
    ch_name=$(y ".chaincodes[$cci].channels[$j]")
    CH_ORG_COUNT=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs | length" "$CONFIG")
    for (( ao=0; ao<CH_ORG_COUNT; ao++ )); do
      ch_org=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs[$ao].name" "$CONFIG")
      for (( k=0; k<CC_ORG_COUNT; k++ )); do
        cc_org=$(y ".chaincodes[$cci].orgs[$k]")
        if [[ "$ch_org" == "$cc_org" ]]; then
          KEY="${CC_NAME}|${cc_org}"
          if [[ -z "${SEEN_CCAAS[$KEY]:-}" ]]; then
            SEEN_CCAAS[$KEY]=1
            org_ns=$(org_field "$cc_org" "namespace")
            log "Deleting CCAAS deployment: ${CC_NAME} in ${org_ns}"
            kubectl delete deployment "$CC_NAME" -n "$org_ns" --ignore-not-found
            kubectl delete service "$CC_NAME" -n "$org_ns" --ignore-not-found
          fi
          break
        fi
      done
    done
  done
done

# ==========================================================================
# 2. Delete Network Configs (per-channel per-org)
# ==========================================================================
log "===== Deleting Network Configs ====="

for (( ci=0; ci<CHANNEL_COUNT; ci++ )); do
  CH_NAME=$(y ".channels[$ci].name")
  CH_ORG_COUNT=$(y ".channels[$ci].orgs | length")
  for (( j=0; j<CH_ORG_COUNT; j++ )); do
    org_name=$(y ".channels[$ci].orgs[$j].name")
    org_ns=$(org_field "$org_name" "namespace")
    NC_NAME="${org_name}-${CH_NAME}-cp"
    log "Deleting network config: $NC_NAME"
    kubectl delete fabricnetworkconfigs.hlf.kungfusoftware.es "$NC_NAME" -n "$org_ns" --ignore-not-found
    kubectl delete secret "$NC_NAME" -n "$org_ns" --ignore-not-found
  done
done

# ==========================================================================
# 3. Delete Follower Channels
# ==========================================================================
log "===== Deleting Follower Channels ====="

for (( ci=0; ci<CHANNEL_COUNT; ci++ )); do
  CH_NAME=$(y ".channels[$ci].name")
  CH_ORG_COUNT=$(y ".channels[$ci].orgs | length")
  for (( j=0; j<CH_ORG_COUNT; j++ )); do
    org_name=$(y ".channels[$ci].orgs[$j].name")
    org_ns=$(org_field "$org_name" "namespace")
    FOLLOWER_NAME="${CH_NAME}-${org_name}"
    log "Deleting FabricFollowerChannel: $FOLLOWER_NAME"
    kubectl delete fabricfollowerchannels.hlf.kungfusoftware.es "$FOLLOWER_NAME" -n "$org_ns" --ignore-not-found
  done
done

# ==========================================================================
# 4. Delete Main Channels
# ==========================================================================
log "===== Deleting Main Channels ====="

for (( ci=0; ci<CHANNEL_COUNT; ci++ )); do
  CH_NAME=$(y ".channels[$ci].name")
  log "Deleting FabricMainChannel: $CH_NAME"
  kubectl delete fabricmainchannels.hlf.kungfusoftware.es "$CH_NAME" --ignore-not-found
done

# ==========================================================================
# 5. Delete Identities (admin certs)
# ==========================================================================
log "===== Deleting Admin Identities ====="

# Orderer admin
log "Deleting orderer admin identities"
kubectl delete fabricidentities.hlf.kungfusoftware.es orderer-admin -n "$ORD_NS" --ignore-not-found
kubectl delete fabricidentities.hlf.kungfusoftware.es orderer-admin-tls -n "$ORD_NS" --ignore-not-found

# Org admins
for (( oi=0; oi<ORG_COUNT; oi++ )); do
  ORG_NAME=$(y ".orgs[$oi].name")
  ORG_NS=$(y ".orgs[$oi].namespace")
  log "Deleting admin identities for $ORG_NAME"
  kubectl delete fabricidentities.hlf.kungfusoftware.es "${ORG_NAME}-admin" -n "$ORG_NS" --ignore-not-found
  kubectl delete fabricidentities.hlf.kungfusoftware.es "${ORG_NAME}-admin-tls" -n "$ORG_NS" --ignore-not-found
done

# ==========================================================================
# 6. Delete Peers
# ==========================================================================
log "===== Deleting Peers ====="

for (( oi=0; oi<ORG_COUNT; oi++ )); do
  ORG_NAME=$(y ".orgs[$oi].name")
  ORG_NS=$(y ".orgs[$oi].namespace")
  PEER_COUNT=$(y ".orgs[$oi].peer_count")

  for (( pi=0; pi<PEER_COUNT; pi++ )); do
    log "Deleting peer${pi} for $ORG_NAME"
    kubectl delete fabricpeers.hlf.kungfusoftware.es "peer${pi}" -n "$ORG_NS" --ignore-not-found
  done
done

# Wait for peers to be fully removed
log "Waiting for all peers to be deleted..."
sleep 5

# ==========================================================================
# 7. Delete Orderers
# ==========================================================================
log "===== Deleting Orderer Nodes ====="

for (( i=0; i<ORD_COUNT; i++ )); do
  log "Deleting orderer${i}"
  kubectl delete fabricorderernodes.hlf.kungfusoftware.es "orderer${i}" -n "$ORD_NS" --ignore-not-found
done

log "Waiting for all orderers to be deleted..."
sleep 5

# ==========================================================================
# 8. Delete CAs
# ==========================================================================
log "===== Deleting Certificate Authorities ====="

log "Deleting orderer CA: $ORD_CA"
kubectl delete fabriccas.hlf.kungfusoftware.es "$ORD_CA" -n "$ORD_NS" --ignore-not-found

for (( oi=0; oi<ORG_COUNT; oi++ )); do
  ORG_NAME=$(y ".orgs[$oi].name")
  ORG_NS=$(y ".orgs[$oi].namespace")
  ORG_CA=$(y ".orgs[$oi].ca_name")
  log "Deleting CA for $ORG_NAME: $ORG_CA"
  kubectl delete fabriccas.hlf.kungfusoftware.es "$ORG_CA" -n "$ORG_NS" --ignore-not-found
done

log "Waiting for all CAs to be deleted..."
sleep 5

# ==========================================================================
# 9. Clean up PVCs (persistent data)
# ==========================================================================
log "===== Deleting PVCs ====="

# Orderer namespace PVCs
log "Deleting PVCs in $ORD_NS"
kubectl delete pvc --all -n "$ORD_NS" --ignore-not-found

# Org namespace PVCs
for (( oi=0; oi<ORG_COUNT; oi++ )); do
  ORG_NS=$(y ".orgs[$oi].namespace")
  log "Deleting PVCs in $ORG_NS"
  kubectl delete pvc --all -n "$ORG_NS" --ignore-not-found
done

# ==========================================================================
# 10. Delete namespaces (optional)
# ==========================================================================
if ! $KEEP_NAMESPACES; then
  log "===== Deleting Namespaces ====="

  if confirm "Delete ALL namespaces (orderer + org namespaces)?"; then
    # Collect unique namespaces
    NAMESPACES=("$ORD_NS")
    for (( oi=0; oi<ORG_COUNT; oi++ )); do
      NS=$(y ".orgs[$oi].namespace")
      # Add if not already in list
      found=false
      for existing in "${NAMESPACES[@]}"; do
        if [[ "$existing" == "$NS" ]]; then found=true; break; fi
      done
      if ! $found; then NAMESPACES+=("$NS"); fi
    done

    for ns in "${NAMESPACES[@]}"; do
      log "Deleting namespace: $ns"
      kubectl delete namespace "$ns" --ignore-not-found
    done

    log "Waiting for namespaces to be deleted..."
    for ns in "${NAMESPACES[@]}"; do
      kubectl wait --for=delete "namespace/$ns" --timeout=120s 2>/dev/null || true
    done
  fi
else
  log "Keeping namespaces (--keep-namespaces)"
fi

log "========================================="
log "HLF Cleanup Complete!"
log "You can now run: ./hlf-deploy.sh $CONFIG"
log "========================================="
