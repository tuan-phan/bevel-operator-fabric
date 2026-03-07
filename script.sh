cat <<'EOF' > hlf-deploy.sh
#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }

confirm() {
  local q="$1"
  read -r -p "$q [y/N]: " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

# -------------------------
# 0) Preflight
# -------------------------
kubectl version --client >/dev/null

# -------------------------
# 1) Deploy CA (EXACT)
# -------------------------
log "1) Deploy CA: restart operator + exports (EXACT)"
kubectl rollout restart deployment hlf-operator-controller-manager -n fabric
sleep 10s

export PEER_IMAGE=hyperledger/fabric-peer
export PEER_VERSION=3.1.3
export ORDERER_IMAGE=hyperledger/fabric-orderer
export ORDERER_VERSION=3.1.3
export CA_IMAGE=hyperledger/fabric-ca
export CA_VERSION=1.5.16
export STORAGE_CLASS=default

if confirm "Create CA for orderer (orderer-ca)?"; then
  kubectl create namespace orderer || true

  kubectl hlf ca create \
    --name=orderer-ca \
    --namespace=orderer \
    --image=$CA_IMAGE \
    --version=$CA_VERSION \
    --storage-class=$STORAGE_CLASS \
    --capacity=1Gi \
    --enroll-id=enroll \
    --enroll-pw=enrollpw \
    --hosts=orderer-ca.orderer.svc.cluster.local \
    --istio-ingressgateway="" \
    --gateway-api-name=""
else
  log "Skipping orderer CA creation"
fi

if confirm "Create CA for nodeb (nodeb-ca)?"; then
  kubectl create namespace nodeb || true

  kubectl hlf ca create \
    --name=nodeb-ca \
    --namespace=nodeb \
    --image=$CA_IMAGE \
    --version=$CA_VERSION \
    --storage-class=$STORAGE_CLASS \
    --capacity=1Gi \
    --enroll-id=enroll \
    --enroll-pw=enrollpw \
    --hosts=nodeb-ca.nodeb.svc.cluster.local \
    --istio-ingressgateway="" \
    --gateway-api-name=""
else
  log "Skipping nodeb CA creation"
fi

kubectl get fabriccas.hlf.kungfusoftware.es -A || true
echo "Waiting ..."
kubectl wait --timeout=180s --for=condition=Running fabriccas.hlf.kungfusoftware.es --all-namespaces --all

# -------------------------
# 2) Register orderer users (EXACT)
# -------------------------
if confirm "2) Register orderer0/1/2 in orderer-ca?"; then
  kubectl hlf ca register \
    --name=orderer-ca \
    --namespace=orderer \
    --user=orderer0 \
    --secret=orderer0pw \
    --type=orderer \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --ca-url=https://orderer-ca.orderer:7054 \
    --mspid=ordererMSP

  kubectl hlf ca register \
    --name=orderer-ca \
    --namespace=orderer \
    --user=orderer1 \
    --secret=orderer1pw \
    --type=orderer \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --ca-url=https://orderer-ca.orderer:7054 \
    --mspid=ordererMSP

  kubectl hlf ca register \
    --name=orderer-ca \
    --namespace=orderer \
    --user=orderer2 \
    --secret=orderer2pw \
    --type=orderer \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --ca-url=https://orderer-ca.orderer:7054 \
    --mspid=ordererMSP
else
  log "Skipping orderer registration"
fi

# -------------------------
# 3) Deploy Orderer nodes (EXACT)
# -------------------------
if confirm "3) Deploy orderer nodes (orderer0/1/2)?"; then
  kubectl hlf ordnode create \
    --image=$ORDERER_IMAGE \
    --version=$ORDERER_VERSION \
    --storage-class=$STORAGE_CLASS \
    --enroll-id=orderer0 \
    --enroll-pw=orderer0pw \
    --mspid=ordererMSP \
    --capacity=2Gi \
    --name=orderer0 \
    --ca-port=7054 \
    --ca-name=orderer-ca.orderer \
    --gateway-api-name="" \
    --istio-ingressgateway="" \
    --hosts=orderer0.orderer.svc.cluster.local \
    --namespace=orderer

  kubectl hlf ordnode create \
    --image=$ORDERER_IMAGE \
    --version=$ORDERER_VERSION \
    --storage-class=$STORAGE_CLASS \
    --enroll-id=orderer1 \
    --enroll-pw=orderer1pw \
    --mspid=ordererMSP \
    --capacity=2Gi \
    --name=orderer1 \
    --ca-port=7054 \
    --ca-name=orderer-ca.orderer \
    --gateway-api-name="" \
    --istio-ingressgateway="" \
    --hosts=orderer1.orderer.svc.cluster.local \
    --namespace=orderer

  kubectl hlf ordnode create \
    --image=$ORDERER_IMAGE \
    --version=$ORDERER_VERSION \
    --storage-class=$STORAGE_CLASS \
    --enroll-id=orderer2 \
    --enroll-pw=orderer2pw \
    --mspid=ordererMSP \
    --capacity=2Gi \
    --name=orderer2 \
    --ca-port=7054 \
    --ca-name=orderer-ca.orderer \
    --gateway-api-name="" \
    --istio-ingressgateway="" \
    --hosts=orderer2.orderer.svc.cluster.local \
    --namespace=orderer

  kubectl get fabricorderernodes.hlf.kungfusoftware.es -A || true
  kubectl wait --timeout=180s --for=condition=Running fabricorderernodes.hlf.kungfusoftware.es --all-namespaces --all
else
  log "Skipping orderer deployment"
fi

# -------------------------
# 4) Deploy peers (EXACT) - no patch
# -------------------------
if confirm "4) Register peer0/peer1 + deploy peers?"; then
  kubectl hlf ca register \
    --name=nodeb-ca \
    --user=peer0 \
    --secret=peer0pw \
    --type=peer \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --mspid nodebMSP \
    --ca-url=https://nodeb-ca.nodeb:7054 \
    --namespace=nodeb

  kubectl hlf ca register \
    --name=nodeb-ca \
    --user=peer1 \
    --secret=peer1pw \
    --type=peer \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --mspid nodebMSP \
    --ca-url=https://nodeb-ca.nodeb:7054 \
    --namespace=nodeb

  kubectl hlf peer create \
    --name=peer0 \
    --namespace=nodeb \
    --mspid=nodebMSP \
    --enroll-id=peer0 \
    --enroll-pw=peer0pw \
    --ca-name=nodeb-ca.nodeb \
    --ca-host=nodeb-ca.nodeb.svc.cluster.local \
    --ca-port=7054 \
    --capacity=5Gi \
    --storage-class=default \
    --gateway-api-name="" \
    --istio-ingressgateway="" \
    --hosts=peer0.nodeb.svc.cluster.local \
    --statedb=couchdb

  kubectl hlf peer create \
    --name=peer1 \
    --namespace=nodeb \
    --mspid=nodebMSP \
    --enroll-id=peer1 \
    --enroll-pw=peer1pw \
    --ca-name=nodeb-ca.nodeb \
    --ca-host=nodeb-ca.nodeb.svc.cluster.local \
    --ca-port=7054 \
    --capacity=5Gi \
    --storage-class=default \
    --storage-class=default \
    --gateway-api-name="" \
    --hosts=peer1.nodeb.svc.cluster.local \
    --statedb=couchdb

  kubectl get fabricpeers.hlf.kungfusoftware.es -A || true
  kubectl wait --timeout=180s --for=condition=Running fabricpeers.hlf.kungfusoftware.es --all-namespaces --all
else
  log "Skipping peer deployment"
fi

# -------------------------
# 5) Create channel identities (EXACT)
# -------------------------
if confirm "5) Create channel identities (orderer-admin / nodeb-admin)?"; then
  kubectl hlf ca register \
    --name orderer-ca \
    --namespace orderer \
    --user ordadmin \
    --secret ordadminpw \
    --type admin \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --ca-url https://orderer-ca.orderer:7054 \
    --mspid ordererMSP

  kubectl hlf identity create \
    --name orderer-admin \
    --namespace orderer \
    --ca-name orderer-ca \
    --ca-namespace orderer \
    --ca ca \
    --mspid ordererMSP \
    --enroll-id ordadmin \
    --enroll-secret ordadminpw

  kubectl hlf identity create \
    --name orderer-admin-tls \
    --namespace orderer \
    --ca-name orderer-ca \
    --ca-namespace orderer \
    --ca tlsca \
    --mspid ordererMSP \
    --enroll-id ordadmin \
    --enroll-secret ordadminpw

  kubectl hlf ca register \
    --name nodeb-ca \
    --namespace nodeb \
    --user admin \
    --secret adminpw \
    --type admin \
    --enroll-id enroll \
    --enroll-secret enrollpw \
    --ca-url https://nodeb-ca.nodeb:7054 \
    --mspid nodebMSP

  kubectl hlf identity create \
    --name nodeb-admin \
    --namespace nodeb \
    --ca-name nodeb-ca \
    --ca-namespace nodeb \
    --ca ca \
    --mspid nodebMSP \
    --enroll-id admin \
    --enroll-secret adminpw

  kubectl hlf identity create \
    --name nodeb-admin-tls \
    --namespace nodeb \
    --ca-name nodeb-ca \
    --ca-namespace nodeb \
    --ca tlsca \
    --mspid nodebMSP \
    --enroll-id admin \
    --enroll-secret adminpw
else
  log "Skipping identity creation"
fi

# -------------------------
# 6) Join channel (FabricMainChannel) (EXACT)
# -------------------------
if confirm "6) Apply FabricMainChannel (oem-group)?"; then
  export PEER_ORG_SIGN_CERT=$(kubectl get fabriccas nodeb-ca -o=jsonpath='{.status.ca_cert}' -n nodeb)
  export PEER_ORG_TLS_CERT=$(kubectl get fabriccas nodeb-ca -o=jsonpath='{.status.tlsca_cert}' -n nodeb)

  export IDENT_8=$(printf "%8s" "")
  export ORDERER_TLS_CERT=$(kubectl get fabriccas orderer-ca -o=jsonpath='{.status.tlsca_cert}' -n orderer | sed -e "s/^/${IDENT_8}/" )
  export ORDERER0_TLS_CERT=$(kubectl get fabricorderernodes orderer0 -o=jsonpath='{.status.tlsCert}' -n orderer | sed -e "s/^/${IDENT_8}/" )
  export ORDERER1_TLS_CERT=$(kubectl get fabricorderernodes orderer1 -o=jsonpath='{.status.tlsCert}' -n orderer | sed -e "s/^/${IDENT_8}/" )
  export ORDERER2_TLS_CERT=$(kubectl get fabricorderernodes orderer2 -o=jsonpath='{.status.tlsCert}' -n orderer | sed -e "s/^/${IDENT_8}/" )

  kubectl apply -f - <<EOF2
apiVersion: hlf.kungfusoftware.es/v1alpha1
kind: FabricMainChannel
metadata:
  name: oem-group
spec:
  name: oem-group

  adminOrdererOrganizations:
    - mspID: ordererMSP

  adminPeerOrganizations:
    - mspID: nodebMSP

  externalOrdererOrganizations: []
  externalPeerOrganizations: []

  channelConfig:
    capabilities:
      - V2_0
    policies: null

    orderer:
      ordererType: etcdraft
      state: STATE_NORMAL
      batchTimeout: 0.5s
      batchSize:
        maxMessageCount: 200
        absoluteMaxBytes: 1048576
        preferredMaxBytes: 524288
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
    - mspID: nodebMSP
      caName: nodeb-ca
      caNamespace: nodeb

  identities:
    ordererMSP:
      secretName: orderer-admin
      secretNamespace: orderer
      secretKey: user.yaml

    ordererMSP-tls:
      secretName: orderer-admin-tls
      secretNamespace: orderer
      secretKey: user.yaml

    nodebMSP:
      secretName: nodeb-admin
      secretNamespace: nodeb
      secretKey: user.yaml

  ordererOrganizations:
    - mspID: ordererMSP
      caName: orderer-ca
      caNamespace: orderer

      ordererEndpoints:
        - orderer0.orderer:7050
        - orderer1.orderer:7050
        - orderer2.orderer:7050

      externalOrderersToJoin:
        - host: orderer0.orderer
          port: 7053
        - host: orderer1.orderer
          port: 7053
        - host: orderer2.orderer
          port: 7053

      orderersToJoin: []

  orderers:
    - host: orderer0.orderer
      port: 7050
      tlsCert: |-
${ORDERER0_TLS_CERT}
    - host: orderer1.orderer
      port: 7050
      tlsCert: |-
${ORDERER1_TLS_CERT}
    - host: orderer2.orderer
      port: 7050
      tlsCert: |-
${ORDERER2_TLS_CERT}
EOF2

  kubectl get fabricmainchannel.hlf.kungfusoftware.es || true
else
  log "Skipping FabricMainChannel"
fi

# -------------------------
# 7) Create follower channel (EXACT)
# -------------------------
if confirm "7) Apply FabricFollowerChannel (oem-group-nodeb)?"; then
  export IDENT_8=$(printf "%8s" "")
  export ORDERER0_TLS_CERT=$(kubectl get fabricorderernodes orderer0 -n orderer \
    -o jsonpath='{.status.tlsCert}' | sed -e "s/^/${IDENT_8}/")

  kubectl apply -f - <<EOF3
apiVersion: hlf.kungfusoftware.es/v1alpha1
kind: FabricFollowerChannel
metadata:
  name: oem-group-nodeb
  namespace: nodeb
spec:
  name: oem-group
  mspId: nodebMSP

  anchorPeers:
    - host: peer0.nodeb.svc.cluster.local
      port: 7051

  hlfIdentity:
    secretName: nodeb-admin
    secretNamespace: nodeb
    secretKey: user.yaml

  externalPeersToJoin: []

  orderers:
    - url: grpcs://orderer0.orderer:7050
      certificate: |
${ORDERER0_TLS_CERT}

  peersToJoin:
    - name: peer0
      namespace: nodeb
    - name: peer1
      namespace: nodeb
EOF3

  kubectl get fabricfollowerchannel.hlf.kungfusoftware.es -A || true
else
  log "Skipping follower channel"
fi

# -------------------------
# 8) Create hlf networkconfig (EXACT)
# -------------------------
if confirm "8) Create hlf networkconfig (nodeb-cp)?"; then
  kubectl hlf networkconfig create \
    --name=nodeb-cp \
    -c oem-group \
    -o nodebMSP \
    -o ordererMSP \
    --identities=nodeb-admin.nodeb \
    --secret=nodeb-cp \
    -n nodeb

  kubectl get fabricnetworkconfigs.hlf.kungfusoftware.es -A || true
else
  log "Skipping networkconfig"
fi

# -------------------------
# 9) Create chaincode (EXACT)
# -------------------------
if confirm "9) Deploy chaincode (asset) end-to-end?"; then
  kubectl get secret nodeb-cp -n nodeb \
    -o jsonpath="{.data.config\.yaml}" | base64 --decode > nodeb.yaml

  rm -f code.tar.gz chaincode.tgz
  export CHAINCODE_NAME=asset
  export CHAINCODE_LABEL=asset

  cat > metadata.json <<EOF4
{
  "type": "ccaas",
  "label": "${CHAINCODE_LABEL}"
}
EOF4

  cat > connection.json <<EOF5
{
  "address": "${CHAINCODE_NAME}.nodeb.svc.cluster.local:7052",
  "dial_timeout": "10s",
  "tls_required": false
}
EOF5

  tar czf code.tar.gz connection.json
  tar czf chaincode.tgz metadata.json code.tar.gz

  export PACKAGE_ID=$(kubectl hlf chaincode calculatepackageid \
    --path=chaincode.tgz \
    --language=golang \
    --label=$CHAINCODE_LABEL)

  echo $PACKAGE_ID

  kubectl hlf chaincode install \
    --path=chaincode.tgz \
    --config=nodeb.yaml \
    --language=golang \
    --label=$CHAINCODE_LABEL \
    --user=nodeb-admin-nodeb \
    --peer=peer0.nodeb

  kubectl hlf chaincode install \
    --path=chaincode.tgz \
    --config=nodeb.yaml \
    --language=golang \
    --label=$CHAINCODE_LABEL \
    --user=nodeb-admin-nodeb \
    --peer=peer1.nodeb

  export CC_NAME=asset
  export CC_VERSION=1.0
  export CC_SEQUENCE=1

  kubectl hlf chaincode approveformyorg \
    --config=nodeb.yaml \
    --user=nodeb-admin-nodeb \
    --peer=peer0.nodeb \
    --channel=oem-group \
    --name=$CC_NAME \
    --version=$CC_VERSION \
    --sequence=$CC_SEQUENCE \
    --package-id=$PACKAGE_ID \
    --policy="OR('nodebMSP.member')" \
    --init-required=false

  log "Committing chaincode definition (retry-safe)"
  for i in {1..5}; do
    sleep 10s
    if kubectl hlf chaincode commit \
      --config=nodeb.yaml \
      --user=nodeb-admin-nodeb \
      --mspid=nodebMSP \
      --channel=oem-group \
      --name=$CC_NAME \
      --version=$CC_VERSION \
      --sequence=$CC_SEQUENCE \
      --policy="OR('nodebMSP.member')" \
      --init-required=false; then
      log "Commit succeeded"
      break
    fi
    log "Commit failed. Sleeping 10s and retrying... ($i/5)"
  done

  kubectl hlf chaincode queryinstalled \
    --config=nodeb.yaml \
    --user=nodeb-admin-nodeb \
    --peer=peer0.nodeb

  kubectl hlf externalchaincode sync --image=sktdevacr.azurecr.io/origence-hlf-asset-chaincode:DEVELOP.2625 \
    --name=$CHAINCODE_NAME \
    --namespace=nodeb \
    --package-id=$PACKAGE_ID \
    --tls-required=false \
    --replicas=1

  kubectl wait --for=create deployment/asset -n nodeb --timeout=180s && kubectl wait --for=condition=Available deployment/asset -n nodeb --timeout=180s
  sleep 30s
  log "Ping HLF system to confirm"
  kubectl hlf chaincode invoke --config=nodeb.yaml \
    --user=nodeb-admin-nodeb --peer=peer0.nodeb \
    --chaincode=asset --channel=oem-group \
    --fcn=Ping

else
  log "Skipping chaincode deploy"
fi

log "Deploy succeeded"
EOF
