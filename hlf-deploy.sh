#!/usr/bin/env bash
# =============================================================================
# HLF Dynamic Deployment Script
# Reads config.yaml and deploys the full Hyperledger Fabric network.
#
# Usage:  ./hlf-deploy.sh [config.yaml] [--skip-confirm] [--step=N]
#
# Requirements: kubectl, kubectl-hlf plugin, yq (v4+)
# =============================================================================
set -euo pipefail

CONFIG="${1:-config.yaml}"
SKIP_CONFIRM=false
START_STEP=1

for arg in "$@"; do
  case "$arg" in
    --skip-confirm) SKIP_CONFIRM=true ;;
    --step=*) START_STEP="${arg#*=}" ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file '$CONFIG' not found"; exit 1
fi

# --- Check dependencies ---
for cmd in kubectl yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not found in PATH"; exit 1
  fi
done

# --- Helpers ---
log()     { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }
confirm() {
  if $SKIP_CONFIRM; then return 0; fi
  local q="$1"
  read -r -p "$q [y/N]: " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

# --- Read global config ---
y() { yq eval "$1" "$CONFIG"; }

PEER_IMAGE=$(y '.global.peer_image')
PEER_VERSION=$(y '.global.peer_version')
ORDERER_IMAGE=$(y '.global.orderer_image')
ORDERER_VERSION=$(y '.global.orderer_version')
CA_IMAGE=$(y '.global.ca_image')
CA_VERSION=$(y '.global.ca_version')
STORAGE_CLASS=$(y '.global.storage_class')
CA_CAPACITY=$(y '.global.ca_capacity')
ORDERER_CAPACITY=$(y '.global.orderer_capacity')
PEER_CAPACITY=$(y '.global.peer_capacity')
PEER_STATEDB=$(y '.global.peer_statedb')
ENROLL_ID=$(y '.global.enroll_id')
ENROLL_PW=$(y '.global.enroll_pw')

ORD_NS=$(y '.orderer.namespace')
ORD_MSPID=$(y '.orderer.mspid')
ORD_CA=$(y '.orderer.ca_name')
ORD_ADMIN_USER=$(y '.orderer.admin_user')
ORD_ADMIN_PW=$(y '.orderer.admin_pw')
ORD_COUNT=$(y '.orderer.count')

ORG_COUNT=$(y '.orgs | length')
CHANNEL_COUNT=$(y '.channels | length')
CC_COUNT=$(y '.chaincodes | length')

# --- Org lookup helpers ---
org_field() {
  # org_field <org_name> <field>
  local name="$1" field="$2"
  yq eval ".orgs[] | select(.name == \"$name\") | .$field" "$CONFIG"
}

# ==========================================================================
# STEP 1: Deploy CAs
# ==========================================================================
if (( START_STEP <= 1 )); then
log "===== STEP 1: Deploy Certificate Authorities ====="

if confirm "Deploy orderer CA ($ORD_CA)?"; then
  kubectl create namespace "$ORD_NS" 2>/dev/null || true

  kubectl hlf ca create \
    --name="$ORD_CA" \
    --namespace="$ORD_NS" \
    --image="$CA_IMAGE" \
    --version="$CA_VERSION" \
    --storage-class="$STORAGE_CLASS" \
    --capacity="$CA_CAPACITY" \
    --enroll-id="$ENROLL_ID" \
    --enroll-pw="$ENROLL_PW" \
    --hosts="${ORD_CA}.${ORD_NS}.svc.cluster.local" \
    --istio-ingressgateway="" \
    --gateway-api-name=""
  log "Orderer CA created"
fi

for (( i=0; i<ORG_COUNT; i++ )); do
  ORG_NAME=$(y ".orgs[$i].name")
  ORG_NS=$(y ".orgs[$i].namespace")
  ORG_CA=$(y ".orgs[$i].ca_name")

  if confirm "Deploy CA for org '$ORG_NAME' ($ORG_CA)?"; then
    kubectl create namespace "$ORG_NS" 2>/dev/null || true

    kubectl hlf ca create \
      --name="$ORG_CA" \
      --namespace="$ORG_NS" \
      --image="$CA_IMAGE" \
      --version="$CA_VERSION" \
      --storage-class="$STORAGE_CLASS" \
      --capacity="$CA_CAPACITY" \
      --enroll-id="$ENROLL_ID" \
      --enroll-pw="$ENROLL_PW" \
      --hosts="${ORG_CA}.${ORG_NS}.svc.cluster.local" \
      --istio-ingressgateway="" \
      --gateway-api-name=""
    log "CA for $ORG_NAME created"
  fi
done

log "Waiting for all CAs to be Running..."
kubectl wait --timeout=180s --for=condition=Running \
  fabriccas.hlf.kungfusoftware.es --all-namespaces --all
fi

# ==========================================================================
# STEP 2: Register & Deploy Orderers
# ==========================================================================
if (( START_STEP <= 2 )); then
log "===== STEP 2: Register & Deploy Orderer Nodes ====="

if confirm "Register and deploy $ORD_COUNT orderer nodes?"; then
  for (( i=0; i<ORD_COUNT; i++ )); do
    log "Registering orderer${i}..."
    kubectl hlf ca register \
      --name="$ORD_CA" \
      --namespace="$ORD_NS" \
      --user="orderer${i}" \
      --secret="orderer${i}pw" \
      --type=orderer \
      --enroll-id "$ENROLL_ID" \
      --enroll-secret "$ENROLL_PW" \
      --ca-url="https://${ORD_CA}.${ORD_NS}:7054" \
      --mspid="$ORD_MSPID"
  done

  for (( i=0; i<ORD_COUNT; i++ )); do
    log "Deploying orderer${i}..."
    kubectl hlf ordnode create \
      --image="$ORDERER_IMAGE" \
      --version="$ORDERER_VERSION" \
      --storage-class="$STORAGE_CLASS" \
      --enroll-id="orderer${i}" \
      --enroll-pw="orderer${i}pw" \
      --mspid="$ORD_MSPID" \
      --capacity="$ORDERER_CAPACITY" \
      --name="orderer${i}" \
      --ca-port=7054 \
      --ca-name="${ORD_CA}.${ORD_NS}" \
      --gateway-api-name="" \
      --istio-ingressgateway="" \
      --hosts="orderer${i}.${ORD_NS}.svc.cluster.local" \
      --namespace="$ORD_NS"
  done

  log "Waiting for all orderer nodes to be Running..."
  kubectl wait --timeout=180s --for=condition=Running \
    fabricorderernodes.hlf.kungfusoftware.es --all-namespaces --all
fi
fi

# ==========================================================================
# STEP 3: Register & Deploy Peers
# ==========================================================================
if (( START_STEP <= 3 )); then
log "===== STEP 3: Register & Deploy Peers ====="

for (( oi=0; oi<ORG_COUNT; oi++ )); do
  ORG_NAME=$(y ".orgs[$oi].name")
  ORG_NS=$(y ".orgs[$oi].namespace")
  ORG_CA=$(y ".orgs[$oi].ca_name")
  ORG_MSPID=$(y ".orgs[$oi].mspid")
  PEER_COUNT=$(y ".orgs[$oi].peer_count")

  if confirm "Register and deploy $PEER_COUNT peers for org '$ORG_NAME'?"; then
    for (( pi=0; pi<PEER_COUNT; pi++ )); do
      log "Registering peer${pi} for $ORG_NAME..."
      kubectl hlf ca register \
        --name="$ORG_CA" \
        --user="peer${pi}" \
        --secret="peer${pi}pw" \
        --type=peer \
        --enroll-id "$ENROLL_ID" \
        --enroll-secret "$ENROLL_PW" \
        --mspid "$ORG_MSPID" \
        --ca-url="https://${ORG_CA}.${ORG_NS}:7054" \
        --namespace="$ORG_NS"
    done

    for (( pi=0; pi<PEER_COUNT; pi++ )); do
      log "Deploying peer${pi} for $ORG_NAME..."
      kubectl hlf peer create \
        --name="peer${pi}" \
        --namespace="$ORG_NS" \
        --mspid="$ORG_MSPID" \
        --enroll-id="peer${pi}" \
        --enroll-pw="peer${pi}pw" \
        --ca-name="${ORG_CA}.${ORG_NS}" \
        --ca-host="${ORG_CA}.${ORG_NS}.svc.cluster.local" \
        --ca-port=7054 \
        --capacity="$PEER_CAPACITY" \
        --storage-class="$STORAGE_CLASS" \
        --gateway-api-name="" \
        --istio-ingressgateway="" \
        --hosts="peer${pi}.${ORG_NS}.svc.cluster.local" \
        --statedb="$PEER_STATEDB"
    done
  fi
done

log "Waiting for all peers to be Running..."
kubectl wait --timeout=180s --for=condition=Running \
  fabricpeers.hlf.kungfusoftware.es --all-namespaces --all
fi

# ==========================================================================
# STEP 4: Create Admin Identities
# ==========================================================================
if (( START_STEP <= 4 )); then
log "===== STEP 4: Create Admin Identities ====="

if confirm "Create admin identities for orderer + all orgs?"; then
  # Orderer admin
  kubectl hlf ca register \
    --name "$ORD_CA" \
    --namespace "$ORD_NS" \
    --user "$ORD_ADMIN_USER" \
    --secret "$ORD_ADMIN_PW" \
    --type admin \
    --enroll-id "$ENROLL_ID" \
    --enroll-secret "$ENROLL_PW" \
    --ca-url "https://${ORD_CA}.${ORD_NS}:7054" \
    --mspid "$ORD_MSPID"

  kubectl hlf identity create \
    --name orderer-admin \
    --namespace "$ORD_NS" \
    --ca-name "$ORD_CA" \
    --ca-namespace "$ORD_NS" \
    --ca ca \
    --mspid "$ORD_MSPID" \
    --enroll-id "$ORD_ADMIN_USER" \
    --enroll-secret "$ORD_ADMIN_PW"

  kubectl hlf identity create \
    --name orderer-admin-tls \
    --namespace "$ORD_NS" \
    --ca-name "$ORD_CA" \
    --ca-namespace "$ORD_NS" \
    --ca tlsca \
    --mspid "$ORD_MSPID" \
    --enroll-id "$ORD_ADMIN_USER" \
    --enroll-secret "$ORD_ADMIN_PW"

  # Org admins
  for (( oi=0; oi<ORG_COUNT; oi++ )); do
    ORG_NAME=$(y ".orgs[$oi].name")
    ORG_NS=$(y ".orgs[$oi].namespace")
    ORG_CA=$(y ".orgs[$oi].ca_name")
    ORG_MSPID=$(y ".orgs[$oi].mspid")
    ORG_ADMIN_USER=$(y ".orgs[$oi].admin_user")
    ORG_ADMIN_PW=$(y ".orgs[$oi].admin_pw")

    log "Creating admin identity for $ORG_NAME..."
    kubectl hlf ca register \
      --name "$ORG_CA" \
      --namespace "$ORG_NS" \
      --user "$ORG_ADMIN_USER" \
      --secret "$ORG_ADMIN_PW" \
      --type admin \
      --enroll-id "$ENROLL_ID" \
      --enroll-secret "$ENROLL_PW" \
      --ca-url "https://${ORG_CA}.${ORG_NS}:7054" \
      --mspid "$ORG_MSPID"

    kubectl hlf identity create \
      --name "${ORG_NAME}-admin" \
      --namespace "$ORG_NS" \
      --ca-name "$ORG_CA" \
      --ca-namespace "$ORG_NS" \
      --ca ca \
      --mspid "$ORG_MSPID" \
      --enroll-id "$ORG_ADMIN_USER" \
      --enroll-secret "$ORG_ADMIN_PW"

    kubectl hlf identity create \
      --name "${ORG_NAME}-admin-tls" \
      --namespace "$ORG_NS" \
      --ca-name "$ORG_CA" \
      --ca-namespace "$ORG_NS" \
      --ca tlsca \
      --mspid "$ORG_MSPID" \
      --enroll-id "$ORG_ADMIN_USER" \
      --enroll-secret "$ORG_ADMIN_PW"
  done
  log "All admin identities created"
fi
fi

# ==========================================================================
# STEP 5: Create Channels (FabricMainChannel + FabricFollowerChannel)
# ==========================================================================
if (( START_STEP <= 5 )); then
log "===== STEP 5: Create Channels ====="

# --- Helper: build orderer endpoints, externalOrderersToJoin, orderers TLS block ---
build_orderer_endpoints() {
  local result=""
  for (( i=0; i<ORD_COUNT; i++ )); do
    result+="        - orderer${i}.${ORD_NS}:7050"$'\n'
  done
  echo "$result"
}

build_external_orderers_to_join() {
  local result=""
  for (( i=0; i<ORD_COUNT; i++ )); do
    result+="        - host: orderer${i}.${ORD_NS}"$'\n'
    result+="          port: 7053"$'\n'
  done
  echo "$result"
}

build_orderers_tls() {
  local IDENT_8
  IDENT_8=$(printf "%8s" "")
  local result=""
  for (( i=0; i<ORD_COUNT; i++ )); do
    local TLS_CERT
    TLS_CERT=$(kubectl get fabricorderernodes "orderer${i}" -n "$ORD_NS" \
      -o jsonpath='{.status.tlsCert}' | sed -e "s/^/${IDENT_8}/")
    result+="    - host: orderer${i}.${ORD_NS}"$'\n'
    result+="      port: 7050"$'\n'
    result+="      tlsCert: |-"$'\n'
    result+="${TLS_CERT}"$'\n'
  done
  echo "$result"
}

# Read channel config (applies to all channels)
BATCH_TIMEOUT=$(y '.channel_config.batch_timeout')
MAX_MSG_COUNT=$(y '.channel_config.batch_size.max_message_count')
ABS_MAX_BYTES=$(y '.channel_config.batch_size.absolute_max_bytes')
PREF_MAX_BYTES=$(y '.channel_config.batch_size.preferred_max_bytes')
log "Channel config: batchTimeout=$BATCH_TIMEOUT, maxMessageCount=$MAX_MSG_COUNT"

for (( ci=0; ci<CHANNEL_COUNT; ci++ )); do
  CH_NAME=$(y ".channels[$ci].name")

  # Get org names for this channel (orgs are now objects with .name and .peers)
  CH_ORG_COUNT=$(y ".channels[$ci].orgs | length")
  CH_ORG_NAMES=()
  for (( j=0; j<CH_ORG_COUNT; j++ )); do
    CH_ORG_NAMES+=( "$(y ".channels[$ci].orgs[$j].name")" )
  done

  if confirm "Create channel '$CH_NAME' with orgs: ${CH_ORG_NAMES[*]}?"; then
    # --- Build peerOrganizations block ---
    PEER_ORGS_BLOCK=""
    ADMIN_PEER_ORGS_BLOCK=""
    IDENTITIES_BLOCK=""

    for org_name in "${CH_ORG_NAMES[@]}"; do
      org_ns=$(org_field "$org_name" "namespace")
      org_mspid=$(org_field "$org_name" "mspid")
      org_ca=$(org_field "$org_name" "ca_name")

      PEER_ORGS_BLOCK+="    - mspID: ${org_mspid}"$'\n'
      PEER_ORGS_BLOCK+="      caName: ${org_ca}"$'\n'
      PEER_ORGS_BLOCK+="      caNamespace: ${org_ns}"$'\n'

      ADMIN_PEER_ORGS_BLOCK+="    - mspID: ${org_mspid}"$'\n'

      IDENTITIES_BLOCK+="    ${org_mspid}:"$'\n'
      IDENTITIES_BLOCK+="      secretName: ${org_name}-admin"$'\n'
      IDENTITIES_BLOCK+="      secretNamespace: ${org_ns}"$'\n'
      IDENTITIES_BLOCK+="      secretKey: user.yaml"$'\n'
    done

    # Orderer identities
    IDENTITIES_BLOCK+="    ${ORD_MSPID}:"$'\n'
    IDENTITIES_BLOCK+="      secretName: orderer-admin"$'\n'
    IDENTITIES_BLOCK+="      secretNamespace: ${ORD_NS}"$'\n'
    IDENTITIES_BLOCK+="      secretKey: user.yaml"$'\n'
    IDENTITIES_BLOCK+="    ${ORD_MSPID}-tls:"$'\n'
    IDENTITIES_BLOCK+="      secretName: orderer-admin-tls"$'\n'
    IDENTITIES_BLOCK+="      secretNamespace: ${ORD_NS}"$'\n'
    IDENTITIES_BLOCK+="      secretKey: user.yaml"$'\n'

    ORDERER_ENDPOINTS=$(build_orderer_endpoints)
    EXTERNAL_ORDERERS=$(build_external_orderers_to_join)
    ORDERERS_TLS=$(build_orderers_tls)

    # Build endorsement policy: OR('org1MSP.member','org2MSP.member',...)
    POLICY_PARTS=""
    for org_name in "${CH_ORG_NAMES[@]}"; do
      org_mspid=$(org_field "$org_name" "mspid")
      if [[ -n "$POLICY_PARTS" ]]; then POLICY_PARTS+=","; fi
      POLICY_PARTS+="'${org_mspid}.member'"
    done

    log "Applying FabricMainChannel: $CH_NAME"
    kubectl apply -f - <<MAINCHANNEL
apiVersion: hlf.kungfusoftware.es/v1alpha1
kind: FabricMainChannel
metadata:
  name: ${CH_NAME}
spec:
  name: ${CH_NAME}

  adminOrdererOrganizations:
    - mspID: ${ORD_MSPID}

  adminPeerOrganizations:
${ADMIN_PEER_ORGS_BLOCK}
  externalOrdererOrganizations: []
  externalPeerOrganizations: []

  channelConfig:
    capabilities:
      - V2_0
    policies: null
    orderer:
      ordererType: etcdraft
      state: STATE_NORMAL
      batchTimeout: ${BATCH_TIMEOUT}
      batchSize:
        maxMessageCount: ${MAX_MSG_COUNT}
        absoluteMaxBytes: ${ABS_MAX_BYTES}
        preferredMaxBytes: ${PREF_MAX_BYTES}
      capabilities:
        - V2_0
      etcdRaft:
        options:
          tickInterval: 500ms
          electionTick: 10
          heartbeatTick: 1
          maxInflightBlocks: 5
          snapshotIntervalSize: 16777216
      policies: null
    application:
      capabilities:
        - V2_0
      policies: null
      acls: null

  peerOrganizations:
${PEER_ORGS_BLOCK}
  identities:
${IDENTITIES_BLOCK}
  ordererOrganizations:
    - mspID: ${ORD_MSPID}
      caName: ${ORD_CA}
      caNamespace: ${ORD_NS}
      ordererEndpoints:
${ORDERER_ENDPOINTS}
      externalOrderersToJoin:
${EXTERNAL_ORDERERS}
      orderersToJoin: []

  orderers:
${ORDERERS_TLS}
MAINCHANNEL

    # --- FabricFollowerChannel for each org in this channel ---
    IDENT_8=$(printf "%8s" "")
    ORDERER0_TLS=$(kubectl get fabricorderernodes orderer0 -n "$ORD_NS" \
      -o jsonpath='{.status.tlsCert}' | sed -e "s/^/${IDENT_8}/")

    for (( oi=0; oi<CH_ORG_COUNT; oi++ )); do
      org_name=$(y ".channels[$ci].orgs[$oi].name")
      org_ns=$(org_field "$org_name" "namespace")
      org_mspid=$(org_field "$org_name" "mspid")

      # Build peersToJoin from explicit peers list in channel config
      PEERS_TO_JOIN=""
      PEER_LIST_COUNT=$(y ".channels[$ci].orgs[$oi].peers | length")
      for (( pi=0; pi<PEER_LIST_COUNT; pi++ )); do
        PEER_NAME=$(y ".channels[$ci].orgs[$oi].peers[$pi]")
        PEERS_TO_JOIN+="    - name: ${PEER_NAME}"$'\n'
        PEERS_TO_JOIN+="      namespace: ${org_ns}"$'\n'
      done

      FOLLOWER_NAME="${CH_NAME}-${org_name}"
      log "Applying FabricFollowerChannel: $FOLLOWER_NAME"

      kubectl apply -f - <<FOLLOWER
apiVersion: hlf.kungfusoftware.es/v1alpha1
kind: FabricFollowerChannel
metadata:
  name: ${FOLLOWER_NAME}
  namespace: ${org_ns}
spec:
  name: ${CH_NAME}
  mspId: ${org_mspid}

  anchorPeers:
    - host: peer0.${org_ns}.svc.cluster.local
      port: 7051

  hlfIdentity:
    secretName: ${org_name}-admin
    secretNamespace: ${org_ns}
    secretKey: user.yaml

  externalPeersToJoin: []

  orderers:
    - url: grpcs://orderer0.${ORD_NS}:7050
      certificate: |
${ORDERER0_TLS}

  peersToJoin:
${PEERS_TO_JOIN}
FOLLOWER
    done

    log "Channel '$CH_NAME' created successfully"
  fi
done

# Wait for all channels to be ready
log "Waiting for all FabricMainChannels to be ready..."
kubectl wait --timeout=300s --for=condition=Running \
  fabricmainchannels.hlf.kungfusoftware.es --all || true

log "Waiting for all FabricFollowerChannels to be ready..."
kubectl wait --timeout=300s --for=condition=Running \
  fabricfollowerchannels.hlf.kungfusoftware.es --all-namespaces --all || true
fi

# ==========================================================================
# STEP 6: Create Network Configs
# ==========================================================================
if (( START_STEP <= 6 )); then
log "===== STEP 6: Create Network Configs ====="

if confirm "Create network configs for all orgs?"; then
  for (( oi=0; oi<ORG_COUNT; oi++ )); do
    ORG_NAME=$(y ".orgs[$oi].name")
    ORG_NS=$(y ".orgs[$oi].namespace")
    ORG_MSPID=$(y ".orgs[$oi].mspid")

    # Collect all channels this org participates in
    ORG_CHANNELS=()
    for (( ci=0; ci<CHANNEL_COUNT; ci++ )); do
      CH_NAME=$(y ".channels[$ci].name")
      CH_ORG_COUNT=$(y ".channels[$ci].orgs | length")
      for (( j=0; j<CH_ORG_COUNT; j++ )); do
        if [[ "$(y ".channels[$ci].orgs[$j].name")" == "$ORG_NAME" ]]; then
          ORG_CHANNELS+=("$CH_NAME")
          break
        fi
      done
    done

    if (( ${#ORG_CHANNELS[@]} == 0 )); then continue; fi

    # Use first channel for networkconfig (it will discover all)
    CHANNEL_FLAGS=""
    for ch in "${ORG_CHANNELS[@]}"; do
      CHANNEL_FLAGS+=" -c $ch"
    done

    log "Creating network config for $ORG_NAME (channels: ${ORG_CHANNELS[*]})..."
    kubectl hlf networkconfig create \
      --name="${ORG_NAME}-cp" \
      $CHANNEL_FLAGS \
      -o "$ORG_MSPID" \
      -o "$ORD_MSPID" \
      --identities="${ORG_NAME}-admin.${ORG_NS}" \
      --secret="${ORG_NAME}-cp" \
      -n "$ORG_NS"
  done
  log "All network configs created"
fi
fi

# ==========================================================================
# STEP 7: Deploy Chaincodes
# ==========================================================================
if (( START_STEP <= 7 )); then
log "===== STEP 7: Deploy Chaincodes ====="

for (( cci=0; cci<CC_COUNT; cci++ )); do
  CC_NAME=$(y ".chaincodes[$cci].name")
  CC_LABEL="$CC_NAME"
  CC_VERSION=$(y ".chaincodes[$cci].version")
  CC_SEQUENCE=$(y ".chaincodes[$cci].sequence")
  CC_IMAGE=$(y ".chaincodes[$cci].image")
  CC_REPLICAS=$(y ".chaincodes[$cci].replicas")

  CC_CHANNEL_COUNT=$(y ".chaincodes[$cci].channels | length")
  CC_ORG_COUNT=$(y ".chaincodes[$cci].orgs | length")

  CC_CHANNELS=()
  for (( j=0; j<CC_CHANNEL_COUNT; j++ )); do
    CC_CHANNELS+=( "$(y ".chaincodes[$cci].channels[$j]")" )
  done

  CC_ORGS=()
  for (( j=0; j<CC_ORG_COUNT; j++ )); do
    CC_ORGS+=( "$(y ".chaincodes[$cci].orgs[$j]")" )
  done

  if ! confirm "Deploy chaincode '$CC_NAME' to channels [${CC_CHANNELS[*]}] for orgs [${CC_ORGS[*]}]?"; then
    continue
  fi

  # --- Collect ALL unique orgs across all channels for this chaincode ---
  ALL_ACTIVE_ORGS=()
  for ch_name in "${CC_CHANNELS[@]}"; do
    CH_ORG_COUNT=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs | length" "$CONFIG")
    for (( ao=0; ao<CH_ORG_COUNT; ao++ )); do
      ch_org=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs[$ao].name" "$CONFIG")
      for cc_org in "${CC_ORGS[@]}"; do
        if [[ "$ch_org" == "$cc_org" ]]; then
          # Add only if not already in list
          local found=false
          for existing in "${ALL_ACTIVE_ORGS[@]+"${ALL_ACTIVE_ORGS[@]}"}"; do
            if [[ "$existing" == "$ch_org" ]]; then found=true; break; fi
          done
          if ! $found; then ALL_ACTIVE_ORGS+=("$ch_org"); fi
          break
        fi
      done
    done
  done
  log "Chaincode '$CC_NAME' unique orgs: ${ALL_ACTIVE_ORGS[*]}"

  # --- For each channel: package, install, approve, commit ---
  for ch_name in "${CC_CHANNELS[@]}"; do
    log "--- Chaincode '$CC_NAME' on channel '$ch_name' ---"

    # Get orgs that belong to THIS channel
    CH_ORG_COUNT=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs | length" "$CONFIG")
    ACTIVE_ORGS=()
    for (( ao=0; ao<CH_ORG_COUNT; ao++ )); do
      ch_org=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs[$ao].name" "$CONFIG")
      for cc_org in "${CC_ORGS[@]}"; do
        if [[ "$ch_org" == "$cc_org" ]]; then
          ACTIVE_ORGS+=("$ch_org")
          break
        fi
      done
    done
    log "Channel '$ch_name' active orgs: ${ACTIVE_ORGS[*]}"

    # For each org IN THIS CHANNEL: package, install, approve
    for org_name in "${ACTIVE_ORGS[@]}"; do
      org_ns=$(org_field "$org_name" "namespace")
      org_mspid=$(org_field "$org_name" "mspid")
      peer_count=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs[] | select(.name == \"$org_name\") | .peers | length" "$CONFIG")

      log "Packaging chaincode for $org_name (channel: $ch_name)..."

      # CCAAS package - connection points to SHARED service (1 per org, no channel suffix)
      TMPDIR=$(mktemp -d)
      cat > "$TMPDIR/metadata.json" <<METAJSON
{
  "type": "ccaas",
  "label": "${CC_NAME}"
}
METAJSON

      cat > "$TMPDIR/connection.json" <<CONNJSON
{
  "address": "${CC_NAME}.${org_ns}.svc.cluster.local:7052",
  "dial_timeout": "10s",
  "tls_required": false
}
CONNJSON

      (cd "$TMPDIR" && tar czf code.tar.gz connection.json && tar czf chaincode.tgz metadata.json code.tar.gz)

      PACKAGE_ID=$(kubectl hlf chaincode calculatepackageid \
        --path="$TMPDIR/chaincode.tgz" \
        --language=golang \
        --label="$CC_NAME")

      log "Package ID: $PACKAGE_ID"

      # Get network config
      kubectl get secret "${org_name}-cp" -n "$org_ns" \
        -o jsonpath="{.data.config\.yaml}" | base64 --decode > "$TMPDIR/${org_name}.yaml"

      # Install on peers listed in channel config
      for (( pi=0; pi<peer_count; pi++ )); do
        PEER_NAME=$(yq eval ".channels[] | select(.name == \"$ch_name\") | .orgs[] | select(.name == \"$org_name\") | .peers[$pi]" "$CONFIG")
        log "Installing on ${PEER_NAME}.${org_ns}..."
        kubectl hlf chaincode install \
          --path="$TMPDIR/chaincode.tgz" \
          --config="$TMPDIR/${org_name}.yaml" \
          --language=golang \
          --label="$CC_NAME" \
          --user="${org_name}-admin-${org_ns}" \
          --peer="${PEER_NAME}.${org_ns}"
      done

      # Build endorsement policy from active orgs in this channel
      POLICY_PARTS=""
      for on in "${ACTIVE_ORGS[@]}"; do
        on_mspid=$(org_field "$on" "mspid")
        if [[ -n "$POLICY_PARTS" ]]; then POLICY_PARTS+=","; fi
        POLICY_PARTS+="'${on_mspid}.member'"
      done

      # Approve
      log "Approving chaincode for $org_name on $ch_name..."
      kubectl hlf chaincode approveformyorg \
        --config="$TMPDIR/${org_name}.yaml" \
        --user="${org_name}-admin-${org_ns}" \
        --peer="peer0.${org_ns}" \
        --channel="$ch_name" \
        --name="$CC_NAME" \
        --version="$CC_VERSION" \
        --sequence="$CC_SEQUENCE" \
        --package-id="$PACKAGE_ID" \
        --policy="OR(${POLICY_PARTS})" \
        --init-required=false

      rm -rf "$TMPDIR"
    done

    # Commit (use first active org)
    FIRST_ORG="${ACTIVE_ORGS[0]}"
    first_org_ns=$(org_field "$FIRST_ORG" "namespace")
    first_org_mspid=$(org_field "$FIRST_ORG" "mspid")

    kubectl get secret "${FIRST_ORG}-cp" -n "$first_org_ns" \
      -o jsonpath="{.data.config\.yaml}" | base64 --decode > "/tmp/${FIRST_ORG}-commit.yaml"

    POLICY_PARTS=""
    for on in "${ACTIVE_ORGS[@]}"; do
      on_mspid=$(org_field "$on" "mspid")
      if [[ -n "$POLICY_PARTS" ]]; then POLICY_PARTS+=","; fi
      POLICY_PARTS+="'${on_mspid}.member'"
    done

    log "Committing chaincode '$CC_NAME' on channel '$ch_name'..."
    for attempt in {1..5}; do
      sleep 10
      if kubectl hlf chaincode commit \
        --config="/tmp/${FIRST_ORG}-commit.yaml" \
        --user="${FIRST_ORG}-admin-${first_org_ns}" \
        --mspid="$first_org_mspid" \
        --channel="$ch_name" \
        --name="$CC_NAME" \
        --version="$CC_VERSION" \
        --sequence="$CC_SEQUENCE" \
        --policy="OR(${POLICY_PARTS})" \
        --init-required=false; then
        log "Commit succeeded"
        break
      fi
      log "Commit attempt $attempt/5 failed, retrying..."
    done
    rm -f "/tmp/${FIRST_ORG}-commit.yaml"

    log "Chaincode '$CC_NAME' committed on channel '$ch_name'"
  done

  # --- Deploy CCAAS: 1 deployment per org (shared across all channels) ---
  for org_name in "${ALL_ACTIVE_ORGS[@]}"; do
    org_ns=$(org_field "$org_name" "namespace")

    TMPDIR=$(mktemp -d)
    cat > "$TMPDIR/metadata.json" <<METAJSON2
{
  "type": "ccaas",
  "label": "${CC_NAME}"
}
METAJSON2
    cat > "$TMPDIR/connection.json" <<CONNJSON2
{
  "address": "${CC_NAME}.${org_ns}.svc.cluster.local:7052",
  "dial_timeout": "10s",
  "tls_required": false
}
CONNJSON2
    (cd "$TMPDIR" && tar czf code.tar.gz connection.json && tar czf chaincode.tgz metadata.json code.tar.gz)

    PACKAGE_ID=$(kubectl hlf chaincode calculatepackageid \
      --path="$TMPDIR/chaincode.tgz" \
      --language=golang \
      --label="$CC_NAME")

    log "Deploying CCAAS '${CC_NAME}' in namespace $org_ns..."
    kubectl hlf externalchaincode sync \
      --image="$CC_IMAGE" \
      --name="${CC_NAME}" \
      --namespace="$org_ns" \
      --package-id="$PACKAGE_ID" \
      --tls-required=false \
      --replicas="$CC_REPLICAS"

    rm -rf "$TMPDIR"
  done

  # Wait for all deployments
  for org_name in "${ALL_ACTIVE_ORGS[@]}"; do
    org_ns=$(org_field "$org_name" "namespace")
    log "Waiting for deployment '${CC_NAME}' in $org_ns..."
    kubectl wait --for=create "deployment/${CC_NAME}" -n "$org_ns" --timeout=180s 2>/dev/null || true
    kubectl wait --for=condition=Available "deployment/${CC_NAME}" -n "$org_ns" --timeout=180s 2>/dev/null || true
  done

  sleep 15

  # Ping test on first channel
  FIRST_ORG="${ALL_ACTIVE_ORGS[0]}"
  first_org_ns=$(org_field "$FIRST_ORG" "namespace")
  kubectl get secret "${FIRST_ORG}-cp" -n "$first_org_ns" \
    -o jsonpath="{.data.config\.yaml}" | base64 --decode > "/tmp/${FIRST_ORG}-ping.yaml"

  log "Ping test: chaincode '$CC_NAME' on channel '${CC_CHANNELS[0]}'..."
  kubectl hlf chaincode invoke \
    --config="/tmp/${FIRST_ORG}-ping.yaml" \
    --user="${FIRST_ORG}-admin-${first_org_ns}" \
    --peer="peer0.${first_org_ns}" \
    --chaincode="$CC_NAME" \
    --channel="${CC_CHANNELS[0]}" \
    --fcn=Ping || log "WARNING: Ping failed (chaincode may not have Ping function)"

  rm -f "/tmp/${FIRST_ORG}-ping.yaml"
  log "Chaincode '$CC_NAME' fully deployed"
done
fi

log "========================================="
log "HLF Network Deployment Complete!"
log "========================================="
