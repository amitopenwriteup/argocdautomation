#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="kind"
ARGOCD_NAMESPACE="argocd"
PORT_FORWARD_PORT="8080"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Kind Cluster + ArgoCD Setup Script${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Step 1: Delete existing Kind cluster
echo -e "${YELLOW}Step 1: Cleaning up existing Kind cluster...${NC}"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Deleting existing cluster: ${CLUSTER_NAME}"
    kind delete cluster --name ${CLUSTER_NAME}
    echo -e "${GREEN}✓ Cluster deleted${NC}\n"
else
    echo -e "${GREEN}✓ No existing cluster found${NC}\n"
fi

# Step 2: Create new Kind cluster
echo -e "${YELLOW}Step 2: Creating new Kind cluster...${NC}"
cat <<EOF | kind create cluster --name ${CLUSTER_NAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
EOF
echo -e "${GREEN}✓ Kind cluster created${NC}\n"

# Step 3: Wait for cluster to be ready
echo -e "${YELLOW}Step 3: Waiting for cluster to be ready...${NC}"
kubectl cluster-info --context kind-${CLUSTER_NAME}
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo -e "${GREEN}✓ Cluster is ready${NC}\n"

# Step 3.5: Check Kubernetes component health
echo -e "${YELLOW}Step 3.5: Checking Kubernetes component health...${NC}"
MAX_RETRIES=3
RETRY_COUNT=0

check_components() {
    echo "Checking core components..."
    
    # Check if all required pods are running
    COREDNS_STATUS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    ETCD_STATUS=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    APISERVER_STATUS=$(kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    CONTROLLER_STATUS=$(kubectl get pods -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    SCHEDULER_STATUS=$(kubectl get pods -n kube-system -l component=kube-scheduler -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    
    # Check component statuses
    COMPONENTS_HEALTHY=true
    
    if [[ ! "$COREDNS_STATUS" =~ "Running" ]]; then
        echo -e "${RED}✗ CoreDNS is not running (Status: $COREDNS_STATUS)${NC}"
        COMPONENTS_HEALTHY=false
    else
        echo -e "${GREEN}✓ CoreDNS is running${NC}"
    fi
    
    if [[ ! "$ETCD_STATUS" =~ "Running" ]]; then
        echo -e "${RED}✗ etcd is not running (Status: $ETCD_STATUS)${NC}"
        COMPONENTS_HEALTHY=false
    else
        echo -e "${GREEN}✓ etcd is running${NC}"
    fi
    
    if [[ ! "$APISERVER_STATUS" =~ "Running" ]]; then
        echo -e "${RED}✗ kube-apiserver is not running (Status: $APISERVER_STATUS)${NC}"
        COMPONENTS_HEALTHY=false
    else
        echo -e "${GREEN}✓ kube-apiserver is running${NC}"
    fi
    
    if [[ ! "$CONTROLLER_STATUS" =~ "Running" ]]; then
        echo -e "${RED}✗ kube-controller-manager is not running (Status: $CONTROLLER_STATUS)${NC}"
        COMPONENTS_HEALTHY=false
    else
        echo -e "${GREEN}✓ kube-controller-manager is running${NC}"
    fi
    
    if [[ ! "$SCHEDULER_STATUS" =~ "Running" ]]; then
        echo -e "${RED}✗ kube-scheduler is not running (Status: $SCHEDULER_STATUS)${NC}"
        COMPONENTS_HEALTHY=false
    else
        echo -e "${GREEN}✓ kube-scheduler is running${NC}"
    fi
    
    if [ "$COMPONENTS_HEALTHY" = false ]; then
        return 1
    else
        return 0
    fi
}

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if check_components; then
        echo -e "${GREEN}✓ All Kubernetes components are healthy${NC}\n"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo -e "${YELLOW}⚠ Components unhealthy. Resetting cluster (Attempt $RETRY_COUNT of $MAX_RETRIES)...${NC}"
            
            # Delete and recreate the cluster
            kind delete cluster --name ${CLUSTER_NAME}
            sleep 5
            
            cat <<EOF | kind create cluster --name ${CLUSTER_NAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
EOF
            
            echo "Waiting for cluster to stabilize..."
            sleep 10
            kubectl wait --for=condition=Ready nodes --all --timeout=60s
        else
            echo -e "${RED}✗ Failed to get healthy components after $MAX_RETRIES attempts${NC}"
            echo -e "${YELLOW}You may need to manually troubleshoot the cluster${NC}\n"
        fi
    fi
done

# Step 4: Install ArgoCD
echo -e "${YELLOW}Step 4: Installing ArgoCD...${NC}"
kubectl create namespace ${ARGOCD_NAMESPACE} 2>/dev/null || true

# Use server-side apply to avoid annotation size limits
echo "Downloading ArgoCD manifests..."
curl -sSL -o /tmp/argocd-install.yaml https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Applying ArgoCD manifests with server-side apply..."
kubectl apply -n ${ARGOCD_NAMESPACE} -f /tmp/argocd-install.yaml --server-side --force-conflicts

echo "Waiting for ArgoCD pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n ${ARGOCD_NAMESPACE} --timeout=300s
echo -e "${GREEN}✓ ArgoCD installed${NC}\n"

# Step 5: Get initial admin password
echo -e "${YELLOW}Step 5: Retrieving initial ArgoCD admin password...${NC}"
sleep 5  # Give a moment for the secret to be created
INITIAL_PASSWORD=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo -e "${GREEN}✓ Initial admin password retrieved${NC}\n"

# Step 6: Get cluster IP
echo -e "${YELLOW}Step 6: Retrieving connection details...${NC}"
ARGOCD_SERVER_IP="localhost"
echo -e "${GREEN}✓ Connection details ready${NC}\n"

# Step 7: Display connection information and port-forward command
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}ArgoCD Setup Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${GREEN}Connection Details:${NC}"
echo "  URL:      https://${ARGOCD_SERVER_IP}:${PORT_FORWARD_PORT}"
echo "  Username: admin"
echo "  Password: ${INITIAL_PASSWORD}"
echo "  IP:       ${ARGOCD_SERVER_IP}"
echo "  Port:     ${PORT_FORWARD_PORT}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}To start port forwarding, run:${NC}"
echo -e "${BLUE}kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0 > argocd-portforward.log 2>&1 &${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}Note:${NC} You may need to accept the self-signed certificate in your browser."
echo -e "${YELLOW}Note:${NC} After running the port-forward command, access ArgoCD at: https://localhost:8080"
