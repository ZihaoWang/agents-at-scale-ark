#!/bin/bash
set -e

# Script to manage Ark lifecycle on macOS with Colima + Minikube
# Usage: ./ark-control.sh [start-minikube|start-ark|delete-ark|delete-minikube]

ACTION=$1

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[ARK-CONTROL]${NC} $1"
}

check_colima() {
    if colima status >/dev/null 2>&1; then
        # Check if it's using QEMU (memory hungry) instead of VZ (Virtualization.framework)
        if pgrep -f "qemu-system-aarch64" >/dev/null; then
            log "${RED}Warning: Colima is running with QEMU (high memory usage detected).${NC}"
            log "Restarting Colima with Apple Virtualization (VZ) for better performance..."
            colima stop
            colima start --cpu 4 --memory 8 --vm-type=vz --vz-rosetta
        else
            log "Colima is already running (optimized)."
        fi
    else
        log "Starting Colima (4 CPU, 8GB RAM, VZ mode)..."
        # Use VZ (Virtualization.framework) + Rosetta for efficient memory usage on Apple Silicon
        colima start --cpu 4 --memory 8 --vm-type=vz --vz-rosetta
    fi
}

check_minikube() {
    if minikube status >/dev/null 2>&1; then
        log "Minikube is already running."
    else
        log "Starting Minikube (Docker driver)..."
        # We explicitly set resources here, though they are constrained by Colima
        minikube start --driver=docker --cpus 4 --memory 7500m
    fi
}

do_start_minikube() {
    log "Initializing Infrastructure..."
    check_colima
    check_minikube
    log "${GREEN}Infrastructure ready.${NC}"
}

do_start_ark() {
    if pgrep -f "devspace dev" >/dev/null; then
        log "${RED}Error: Another DevSpace session is already running.${NC}"
        log "Please check your other terminals, or run './ark-control.sh delete-ark' to force stop it."
        exit 1
    fi
    log "Starting Ark in DevSpace (Minikube profile)..."

    log "Ark is running. You can show available routes by running 'devspace run routes'."

    log "Example output of 'devspace run routes':\n
    info Using namespace 'default'
    info Using kube context 'minikube'
    Available Localhost Gateway routes: 9
    info: Port-forward active on localhost:8080

    argo-workflows: http://argo.127.0.0.1.nip.io:8080/
    argo-workflows: http://argo.default.127.0.0.1.nip.io:8080/
    ark-api       : http://ark-api.127.0.0.1.nip.io:8080/
    ark-api       : http://ark-api.default.127.0.0.1.nip.io:8080/
    ark-dashboard : http://127.0.0.1.nip.io:8080/
    ark-dashboard : http://dashboard.127.0.0.1.nip.io:8080/
    ark-dashboard : http://dashboard.default.127.0.0.1.nip.io:8080/
    minio-console : http://minio.127.0.0.1.nip.io:8080/
    minio-console : http://minio.default.127.0.0.1.nip.io:8080/
    "
    # Use the minikube profile we configured
    devspace dev -p minikube
}

do_delete_ark() {
    log "Stopping local DevSpace processes..."
    pkill -f "devspace" || true
    
    log "Cleaning up Ark resources..."
    
    # 1. Purge DevSpace deployments
    if command -v devspace &> /dev/null; then
        log "Purging DevSpace deployments..."
        devspace purge -p minikube || true
    fi

    # 2. Hard cleanup of namespaces to ensure "brand new" state
    log "Deleting namespaces to ensure clean slate..."
    
    # List of namespaces used by Ark stack
    NAMESPACES=("ark-system" "cert-manager" "minio-operator" "argo")
    
    for ns in "${NAMESPACES[@]}"; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log "Deleting namespace: $ns"
            kubectl delete namespace "$ns" --timeout=60s || log "Warning: Timeout deleting $ns"
        fi
    done

    # 3. Clean up default namespace leftovers (Helm releases that might be in default)
    log "Cleaning up default namespace..."
    helm uninstall argo-workflows -n default 2>/dev/null || true
    helm uninstall ark-tenant -n default 2>/dev/null || true
    helm uninstall ark-api -n default 2>/dev/null || true
    helm uninstall ark-dashboard -n default 2>/dev/null || true
    helm uninstall ark-broker -n default 2>/dev/null || true
    
    # 4. Explicitly delete deployments/pods in default namespace (in case Helm left them)
    log "Sweeping leftover resources in default namespace..."

    # Deployments
    kubectl delete deployment argo-workflows-server argo-workflows-workflow-controller ark-api ark-broker ark-dashboard -n default --ignore-not-found --timeout=30s

    # StatefulSets
    kubectl delete statefulset myminio-pool-0 -n default --ignore-not-found --timeout=30s

    # Services
    kubectl delete svc argo-workflows-server ark-api ark-broker ark-dashboard minio myminio-hl -n default --ignore-not-found --timeout=30s

    # PVCs
    kubectl delete pvc -l app.kubernetes.io/instance=ark-broker -n default --ignore-not-found --timeout=30s
    kubectl delete pvc -l v1.min.io/tenant=myminio -n default --ignore-not-found --timeout=30s
    
    # Force delete any stubborn pods related to ark
    kubectl delete pod -l app.kubernetes.io/instance=ark-api -n default --ignore-not-found --grace-period=0 --force
    kubectl delete pod -l app.kubernetes.io/instance=ark-broker -n default --ignore-not-found --grace-period=0 --force
    kubectl delete pod -l app.kubernetes.io/instance=ark-dashboard -n default --ignore-not-found --grace-period=0 --force
    kubectl delete pod -l app.kubernetes.io/name=argo-workflows-workflow-controller -n default --ignore-not-found --grace-period=0 --force
    kubectl delete pod -l v1.min.io/tenant=myminio -n default --ignore-not-found --grace-period=0 --force
    
    log "${GREEN}Ark resources deleted. Cluster is clean.${NC}"
}

do_delete_minikube() {
    log "${RED}DESTRUCTIVE ACTION: Deleting environment...${NC}"
    
    # 1. Delete Minikube (removes cluster and config)
    if minikube profile list 2>/dev/null | grep -q "minikube"; then
        log "Deleting Minikube cluster..."
        minikube delete
    else
        log "Minikube cluster not found."
    fi

    # 2. Delete Colima (removes VM and config)
    if colima list 2>/dev/null | grep -q "default"; then
        log "Stopping and Deleting Colima VM..."
        colima stop || true
        colima delete --force
    else
        log "Colima VM not found."
    fi
    
    log "${GREEN}Infrastructure deleted.${NC}"
}

case "$ACTION" in
    start-minikube)
        do_start_minikube
        ;;
    start-ark)
        do_start_ark
        ;;
    delete-ark)
        do_delete_ark
        ;;
    delete-minikube)
        do_delete_minikube
        ;;
    *)
        echo "Usage: $0 {start-minikube|start-ark|delete-ark|delete-minikube}"
        echo "  start-minikube : Start Colima (4CPU/8GB) and Minikube"
        echo "  start-ark      : Run Ark using DevSpace"
        echo "  delete-ark     : Remove all Ark apps/namespaces from cluster (Reset)"
        echo "  delete-minikube: Delete Colima VM and Minikube cluster (Full Wipe)"
        exit 1
        ;;
esac
