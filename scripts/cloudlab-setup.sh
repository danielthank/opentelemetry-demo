#!/bin/bash
# CloudLab Node Setup Script
# Run this on each CloudLab node to prepare for opentelemetry-demo deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== CloudLab Node Setup for OpenTelemetry Demo ===${NC}"

# Detect which node this is based on IP
NODE_IP=$(hostname -I | awk '{print $1}')
case $NODE_IP in
    10.10.1.1)
        NODE_ROLE="node0 (Demo Services + Load Generator)"
        ;;
    10.10.1.2)
        NODE_ROLE="node1 (OTel Collector + File-based Trace Storage)"
        ;;
    10.10.1.3)
        NODE_ROLE="node2 (Prometheus + Grafana)"
        ;;
    *)
        NODE_ROLE="Unknown"
        ;;
esac

echo -e "${YELLOW}Detected node: ${NODE_ROLE}${NC}"
echo -e "${YELLOW}IP: ${NODE_IP}${NC}"

# 1. Update system packages
echo -e "${GREEN}[1/7] Updating system packages...${NC}"
sudo apt-get update
sudo apt-get upgrade -y

# 2. Install Docker
echo -e "${GREEN}[2/7] Installing Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
    echo -e "${YELLOW}Docker installed. You may need to log out and back in for group changes.${NC}"
else
    echo "Docker already installed"
fi

# 3. Install Docker Compose
echo -e "${GREEN}[3/7] Installing Docker Compose...${NC}"
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    sudo apt-get install -y docker-compose-plugin
else
    echo "Docker Compose already installed"
fi

# 4. Create data directories
echo -e "${GREEN}[4/7] Creating data directories...${NC}"
sudo mkdir -p /data/otel-traces
sudo mkdir -p /data/tempo
sudo chmod 777 /data/otel-traces
sudo chmod 777 /data/tempo
echo "Created /data/otel-traces and /data/tempo"

# 5. Increase file descriptor limits
echo -e "${GREEN}[5/7] Configuring system limits...${NC}"
if ! grep -q "# OpenTelemetry Demo limits" /etc/security/limits.conf; then
    sudo tee -a /etc/security/limits.conf > /dev/null <<EOF

# OpenTelemetry Demo limits
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF
    echo "File descriptor limits configured"
else
    echo "Limits already configured"
fi

# Also set for current session
ulimit -n 65536 2>/dev/null || true

# 6. Configure sysctl for high network throughput
echo -e "${GREEN}[6/7] Configuring network parameters...${NC}"
if ! grep -q "# OpenTelemetry Demo network settings" /etc/sysctl.conf; then
    sudo tee -a /etc/sysctl.conf > /dev/null <<EOF

# OpenTelemetry Demo network settings
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
EOF
    sudo sysctl -p
    echo "Network parameters configured"
else
    echo "Network parameters already configured"
fi

# 7. Clone repository (if not already present)
echo -e "${GREEN}[7/7] Setting up repository...${NC}"
REPO_DIR="/home/$USER/opentelemetry-demo"
if [ ! -d "$REPO_DIR" ]; then
    git clone https://github.com/open-telemetry/opentelemetry-demo.git "$REPO_DIR"
    cd "$REPO_DIR"
    git checkout gent || echo -e "${YELLOW}Branch 'gent' not found, staying on default branch${NC}"
else
    echo "Repository already exists at $REPO_DIR"
    cd "$REPO_DIR"
    git fetch origin
    git checkout gent 2>/dev/null || echo -e "${YELLOW}Branch 'gent' not found${NC}"
fi

# Summary
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo -e "Node Role: ${YELLOW}${NODE_ROLE}${NC}"
echo -e "Repository: ${YELLOW}${REPO_DIR}${NC}"
echo -e "Trace Storage: ${YELLOW}/data/otel-traces${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Log out and back in (for Docker group membership)"
echo "2. Run the appropriate docker-compose file for this node:"
echo "   - node0: docker compose -f docker-compose.node0-demo.yml up -d"
echo "   - node1: docker compose -f docker-compose.node1-collector.yml up -d"
echo "   - node2: docker compose -f docker-compose.node2-observability.yml up -d"
