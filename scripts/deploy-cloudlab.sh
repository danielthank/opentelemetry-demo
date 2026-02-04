#!/bin/bash
# CloudLab Deployment Orchestration Script
# Run this from your local machine to deploy across all CloudLab nodes

set -e

# CloudLab node configuration
NODE0_IP="128.110.217.51"  # External IP for node0 (demo services)
NODE1_IP="128.110.217.56"  # External IP for node1 (collector)
NODE2_IP="128.110.217.39"  # External IP for node2 (observability)

NODE0_INTERNAL="10.10.1.1"
NODE1_INTERNAL="10.10.1.2"
NODE2_INTERNAL="10.10.1.3"

# SSH user (change if different)
SSH_USER="${SSH_USER:-$(whoami)}"

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Repository path on remote nodes
REPO_PATH="/home/$SSH_USER/opentelemetry-demo"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup        - Run setup script on all nodes"
    echo "  deploy       - Deploy services to all nodes"
    echo "  start        - Start all services"
    echo "  stop         - Stop all services"
    echo "  status       - Check status on all nodes"
    echo "  sync         - Sync local repo to all nodes"
    echo "  logs <node>  - Show logs from a specific node (0, 1, or 2)"
    echo "  collect      - Collect traces from node1"
    echo "  clean        - Stop services and clean up data"
    echo ""
    echo "Environment variables:"
    echo "  SSH_USER     - SSH username (default: current user)"
    echo "  LOCUST_USERS - Number of load generator users (default: 2000)"
}

run_on_node() {
    local ip=$1
    local cmd=$2
    local node_name=$3
    echo -e "${YELLOW}[$node_name] Running: $cmd${NC}"
    ssh $SSH_OPTS $SSH_USER@$ip "$cmd"
}

run_on_all() {
    local cmd=$1
    run_on_node $NODE0_IP "$cmd" "node0" &
    run_on_node $NODE1_IP "$cmd" "node1" &
    run_on_node $NODE2_IP "$cmd" "node2" &
    wait
}

setup() {
    echo -e "${GREEN}=== Setting up all CloudLab nodes ===${NC}"

    # Copy setup script to all nodes
    for node in "$NODE0_IP" "$NODE1_IP" "$NODE2_IP"; do
        echo -e "${YELLOW}Copying setup script to $node...${NC}"
        scp $SSH_OPTS scripts/cloudlab-setup.sh $SSH_USER@$node:/tmp/
        ssh $SSH_OPTS $SSH_USER@$node "chmod +x /tmp/cloudlab-setup.sh && /tmp/cloudlab-setup.sh"
    done
}

sync_repo() {
    echo -e "${GREEN}=== Syncing repository to all nodes ===${NC}"

    # Create tarball of current directory (excluding large dirs)
    echo "Creating archive..."
    tar --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
        --exclude='.venv' --exclude='otel-traces' \
        -czf /tmp/otel-demo.tar.gz -C "$(dirname "$PWD")" "$(basename "$PWD")"

    for node in "$NODE0_IP" "$NODE1_IP" "$NODE2_IP"; do
        echo -e "${YELLOW}Syncing to $node...${NC}"
        scp $SSH_OPTS /tmp/otel-demo.tar.gz $SSH_USER@$node:/tmp/
        ssh $SSH_OPTS $SSH_USER@$node "mkdir -p $REPO_PATH && tar -xzf /tmp/otel-demo.tar.gz -C $REPO_PATH --strip-components=1"
    done

    rm /tmp/otel-demo.tar.gz
    echo -e "${GREEN}Sync complete${NC}"
}

deploy() {
    echo -e "${GREEN}=== Deploying OpenTelemetry Demo ===${NC}"

    # Pull images on all nodes in parallel
    echo -e "${YELLOW}Pulling Docker images on all nodes...${NC}"
    run_on_all "cd $REPO_PATH && docker compose pull" &
    wait

    echo -e "${GREEN}Images pulled successfully${NC}"
}

start() {
    echo -e "${GREEN}=== Starting Services ===${NC}"

    # Start node1 first (collector must be ready)
    echo -e "${YELLOW}Starting collector on node1...${NC}"
    run_on_node $NODE1_IP "cd $REPO_PATH && docker compose -f docker-compose.node1-collector.yml up -d" "node1"

    echo "Waiting for collector to be ready..."
    sleep 10

    # Start node2 (observability - optional)
    echo -e "${YELLOW}Starting observability stack on node2...${NC}"
    run_on_node $NODE2_IP "cd $REPO_PATH && docker compose -f docker-compose.node2-observability.yml up -d" "node2"

    # Start node0 (demo services)
    echo -e "${YELLOW}Starting demo services on node0...${NC}"
    run_on_node $NODE0_IP "cd $REPO_PATH && docker compose -f docker-compose.node0-demo.yml up -d" "node0"

    echo -e "${GREEN}=== All services started ===${NC}"
    echo ""
    echo "Access points:"
    echo "  Frontend:    http://$NODE0_IP:8080"
    echo "  Load Gen UI: http://$NODE0_IP:8089"
    echo "  Grafana:     http://$NODE2_IP:3000"
    echo "  Prometheus:  http://$NODE2_IP:9090"
}

stop() {
    echo -e "${GREEN}=== Stopping all services ===${NC}"

    run_on_node $NODE0_IP "cd $REPO_PATH && docker compose -f docker-compose.node0-demo.yml down" "node0" &
    run_on_node $NODE1_IP "cd $REPO_PATH && docker compose -f docker-compose.node1-collector.yml down" "node1" &
    run_on_node $NODE2_IP "cd $REPO_PATH && docker compose -f docker-compose.node2-observability.yml down" "node2" &
    wait

    echo -e "${GREEN}All services stopped${NC}"
}

status() {
    echo -e "${GREEN}=== Checking status on all nodes ===${NC}"

    for node_info in "node0:$NODE0_IP" "node1:$NODE1_IP" "node2:$NODE2_IP"; do
        node_name="${node_info%%:*}"
        node_ip="${node_info##*:}"
        echo ""
        echo -e "${YELLOW}=== $node_name ($node_ip) ===${NC}"
        ssh $SSH_OPTS $SSH_USER@$node_ip "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null || echo "Failed to connect"
    done

    # Check trace file size on node1
    echo ""
    echo -e "${YELLOW}=== Trace storage on node1 ===${NC}"
    ssh $SSH_OPTS $SSH_USER@$NODE1_IP "ls -lah /data/otel-traces/ 2>/dev/null || echo 'No traces yet'"
}

logs() {
    local node=$1
    case $node in
        0)
            ssh $SSH_OPTS $SSH_USER@$NODE0_IP "cd $REPO_PATH && docker compose -f docker-compose.node0-demo.yml logs -f --tail=100"
            ;;
        1)
            ssh $SSH_OPTS $SSH_USER@$NODE1_IP "cd $REPO_PATH && docker compose -f docker-compose.node1-collector.yml logs -f --tail=100"
            ;;
        2)
            ssh $SSH_OPTS $SSH_USER@$NODE2_IP "cd $REPO_PATH && docker compose -f docker-compose.node2-observability.yml logs -f --tail=100"
            ;;
        *)
            echo "Usage: $0 logs <0|1|2>"
            exit 1
            ;;
    esac
}

collect_traces() {
    echo -e "${GREEN}=== Collecting traces from node1 ===${NC}"

    local output_dir="./collected-traces-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$output_dir"

    echo "Downloading traces to $output_dir..."
    scp $SSH_OPTS "$SSH_USER@$NODE1_IP:/data/otel-traces/*.json" "$output_dir/" 2>/dev/null || echo "No trace files found"

    # Show summary
    if [ -n "$(ls -A "$output_dir" 2>/dev/null)" ]; then
        echo ""
        echo -e "${GREEN}Downloaded traces:${NC}"
        ls -lah "$output_dir"
        echo ""
        echo "Total size: $(du -sh "$output_dir" | cut -f1)"

        # Count approximate number of traces
        total_lines=$(wc -l "$output_dir"/*.json 2>/dev/null | tail -1 | awk '{print $1}')
        echo "Approximate trace count: $total_lines"
    else
        echo "No traces collected yet"
        rmdir "$output_dir"
    fi
}

clean() {
    echo -e "${RED}=== Cleaning up all nodes ===${NC}"
    read -p "This will stop all services and delete trace data. Continue? (y/N) " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 0
    fi

    stop

    echo "Cleaning trace data on node1..."
    ssh $SSH_OPTS $SSH_USER@$NODE1_IP "sudo rm -rf /data/otel-traces/*"

    echo -e "${GREEN}Cleanup complete${NC}"
}

# Main
case "${1:-}" in
    setup)
        setup
        ;;
    sync)
        sync_repo
        ;;
    deploy)
        deploy
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    logs)
        logs "${2:-}"
        ;;
    collect)
        collect_traces
        ;;
    clean)
        clean
        ;;
    *)
        usage
        exit 1
        ;;
esac
