#!/bin/bash
# CloudLab Deployment Orchestration Script
# Run this from your local machine to deploy across all CloudLab nodes

set -e

# CloudLab node configuration
NODE0_IP="128.110.217.149"  # External IP for node0 (demo services)
NODE1_IP="128.110.217.118"  # External IP for node1 (collector)
NODE2_IP="128.110.217.140"  # External IP for node2 (observability)
NODE3_IP="128.110.217.116"  # External IP for node3 (kafka + consumers)

NODE0_INTERNAL="10.10.1.1"
NODE1_INTERNAL="10.10.1.2"
NODE2_INTERNAL="10.10.1.3"
NODE3_INTERNAL="10.10.1.4"

# SSH user (change if different)
SSH_USER="${SSH_USER:-yenruc}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_aws}"

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Repository path on remote nodes
REPO_PATH="/users/$SSH_USER/opentelemetry-demo"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands (most accept optional [node] to target a single node):"
    echo "  upgrade [node]  - Upgrade packages (all nodes or specific node)"
    echo "  terminfo [node] - Copy terminal info (ghostty)"
    echo "  docker [node]   - Install Docker + Compose"
    echo "  config [node]   - Configure system limits"
    echo "  sync [node]     - Sync local repo"
    echo "  build-gent      - Build otelcol-gent image and transfer to node1"
    echo "  deploy [node]   - Pull Docker images"
    echo "  start           - Start all services (ordered)"
    echo "  stop [node]     - Stop services"
    echo "  restart <node> [service] - Restart a node or specific service (e.g., restart 1 loki)"
    echo "  status [node]   - Check container status"
    echo "  logs <node>     - Show logs from a specific node (0, 1, 2, or 3)"
    echo "  collect         - Collect telemetry (traces, metrics, logs) from node1"
    echo "  reset-telemetry - Clear all telemetry data on node1"
    echo "  monitor [node] [-w]  - Show container CPU/memory usage (optional: specific node, -w for watch)"
    echo "  clean        - Stop services and clean up data"
    echo "  ping [node]  - Check if nodes are reachable"
    echo "  reboot [node] - Reboot nodes"
    echo "  ssh <node> <command>  - Run a command on a node (e.g., ssh 3 docker ps)"
    echo ""
    echo "Environment variables:"
    echo "  SSH_USER     - SSH username (default: current user)"
    echo "  SSH_KEY      - SSH private key (default: uses ssh-agent)"
    echo "  LOCUST_USERS - Number of load generator users (default: 2000)"
}

run_on_node() {
    local ip=$1
    local cmd=$2
    local node_name=$3
    echo -e "${YELLOW}[$node_name] Running: $cmd${NC}"
    ssh $SSH_OPTS $SSH_USER@$ip "$cmd"
}

get_node_ip() {
    case $1 in
        0) echo "$NODE0_IP" ;;
        1) echo "$NODE1_IP" ;;
        2) echo "$NODE2_IP" ;;
        3) echo "$NODE3_IP" ;;
        *) echo -e "${RED}Unknown node: $1${NC}" >&2; exit 1 ;;
    esac
}

# Run a command on all nodes, or a single node if specified
# Usage: run_on_nodes <cmd> [node_number]
run_on_nodes() {
    local cmd=$1
    local target=${2:-}

    if [ -n "$target" ]; then
        local ip=$(get_node_ip "$target")
        run_on_node "$ip" "$cmd" "node$target"
    else
        run_on_node $NODE0_IP "$cmd" "node0" &
        run_on_node $NODE1_IP "$cmd" "node1" &
        run_on_node $NODE2_IP "$cmd" "node2" &
        run_on_node $NODE3_IP "$cmd" "node3" &
        wait
    fi
}

copy_terminfo() {
    local target=${1:-}

    if ! infocmp -x xterm-ghostty &>/dev/null; then
        echo -e "${YELLOW}xterm-ghostty terminfo not found locally, skipping${NC}"
        return
    fi

    local nodes
    if [ -n "$target" ]; then
        nodes=("$(get_node_ip "$target")")
        echo -e "${GREEN}=== Installing terminfo on node$target ===${NC}"
    else
        nodes=("$NODE0_IP" "$NODE1_IP" "$NODE2_IP" "$NODE3_IP")
        echo -e "${GREEN}=== Installing terminfo on all nodes ===${NC}"
    fi

    for node in "${nodes[@]}"; do
        echo -e "${YELLOW}Installing terminfo on $node...${NC}"
        infocmp -x xterm-ghostty | ssh $SSH_OPTS $SSH_USER@$node "tic -x -"
    done
    echo -e "${GREEN}Terminfo installed${NC}"
}

upgrade() {
    local target=${1:-}
    echo -e "${GREEN}=== Upgrading packages${target:+ on node$target} ===${NC}"
    run_on_nodes "sudo apt-get update && sudo apt-get upgrade -y" "$target"
}

install_docker() {
    local target=${1:-}
    echo -e "${GREEN}=== Installing Docker${target:+ on node$target} ===${NC}"
    run_on_nodes 'if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER; else echo "Docker already installed"; fi' "$target"
    run_on_nodes 'if ! docker compose version &> /dev/null; then sudo apt-get install -y docker-compose-plugin; else echo "Docker Compose already installed"; fi' "$target"
}

config_limits() {
    local target=${1:-}
    echo -e "${GREEN}=== Configuring system limits${target:+ on node$target} ===${NC}"
    run_on_nodes 'if ! grep -q "# OpenTelemetry Demo limits" /etc/security/limits.conf; then sudo tee -a /etc/security/limits.conf > /dev/null <<EOF

# OpenTelemetry Demo limits
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF
echo "File descriptor limits configured"; else echo "Limits already configured"; fi' "$target"

    run_on_nodes 'if ! grep -q "# OpenTelemetry Demo network settings" /etc/sysctl.conf; then sudo tee -a /etc/sysctl.conf > /dev/null <<EOF

# OpenTelemetry Demo network settings
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
EOF
sudo sysctl -p; echo "Network parameters configured"; else echo "Network parameters already configured"; fi' "$target"
}

sync_repo() {
    local target=${1:-}

    # Build rsync SSH options
    RSYNC_SSH="ssh $SSH_OPTS"

    local nodes
    if [ -n "$target" ]; then
        nodes=("$(get_node_ip "$target")")
        echo -e "${GREEN}=== Syncing repository to node$target ===${NC}"
    else
        nodes=("$NODE0_IP" "$NODE1_IP" "$NODE2_IP" "$NODE3_IP")
        echo -e "${GREEN}=== Syncing repository to all nodes ===${NC}"
    fi

    for node in "${nodes[@]}"; do
        echo -e "${YELLOW}Syncing to $node...${NC}"
        rsync -avz --delete \
            --exclude='.git' \
            --exclude='node_modules' \
            --exclude='__pycache__' \
            --exclude='.venv' \
            --exclude='otel-traces' \
            --exclude='collected-telemetry-*' \
            -e "$RSYNC_SSH" \
            ./ "$SSH_USER@$node:$REPO_PATH/"
    done

    echo -e "${GREEN}Sync complete${NC}"
}

build_gent() {
    echo -e "${GREEN}=== Building otelcol-gent image ===${NC}"

    # Build from the otelcol-gent directory (relative to the workload/opentelemetry-demo scripts dir)
    local gent_dir
    gent_dir="$(cd "$(dirname "$0")/../../.." && pwd)/otelcol-gent"

    if [ ! -d "$gent_dir" ]; then
        echo -e "${RED}otelcol-gent directory not found at $gent_dir${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Building Docker image from $gent_dir...${NC}"
    docker build -t otelcol-gent:latest "$gent_dir"

    echo -e "${YELLOW}Saving image to /tmp/otelcol-gent.tar.gz...${NC}"
    docker save otelcol-gent:latest | gzip > /tmp/otelcol-gent.tar.gz

    echo -e "${YELLOW}Transferring image to node1 ($NODE1_IP)...${NC}"
    rsync -avz --progress -e "ssh $SSH_OPTS" /tmp/otelcol-gent.tar.gz "$SSH_USER@$NODE1_IP:/tmp/otelcol-gent.tar.gz"

    echo -e "${YELLOW}Loading image on node1...${NC}"
    run_on_node $NODE1_IP "gunzip -c /tmp/otelcol-gent.tar.gz | docker load && rm -f /tmp/otelcol-gent.tar.gz" "node1"

    rm -f /tmp/otelcol-gent.tar.gz
    echo -e "${GREEN}otelcol-gent image built and loaded on node1${NC}"
}

deploy() {
    local target=${1:-}

    # Map node number -> compose file for deploy
    deploy_node() {
        local n=$1
        local ip=$(get_node_ip "$n")
        local compose_file
        case $n in
            0) compose_file="docker-compose.node0-demo.yml" ;;
            1) compose_file="docker-compose.node1-collector.yml" ;;
            2) compose_file="docker-compose.node2-observability.yml" ;;
            3) compose_file="docker-compose.node3-kafka.yml" ;;
        esac
        run_on_node "$ip" "cd $REPO_PATH && docker compose -f $compose_file pull" "node$n"
    }

    if [ -n "$target" ]; then
        echo -e "${GREEN}=== Pulling images on node$target ===${NC}"
        deploy_node "$target"
    else
        echo -e "${GREEN}=== Pulling images on all nodes ===${NC}"
        deploy_node 0 &
        deploy_node 1 &
        deploy_node 2 &
        deploy_node 3 &
        wait
    fi

    echo -e "${GREEN}Images pulled successfully${NC}"
}

start() {
    echo -e "${GREEN}=== Starting Services ===${NC}"

    # Start node1 first (collector must be ready)
    echo -e "${YELLOW}Starting collector on node1...${NC}"
    run_on_node $NODE1_IP "cd $REPO_PATH && docker compose -f docker-compose.node1-collector.yml up -d" "node1"

    echo "Waiting for collector to be ready..."
    sleep 10

    # Start node3 (kafka must be up before node0 checkout connects)
    echo -e "${YELLOW}Starting kafka + consumers on node3...${NC}"
    run_on_node $NODE3_IP "cd $REPO_PATH && docker compose -f docker-compose.node3-kafka.yml up -d" "node3"

    echo "Waiting for kafka to be ready..."
    sleep 10

    # Start node2 (observability)
    echo -e "${YELLOW}Starting observability stack on node2...${NC}"
    run_on_node $NODE2_IP "cd $REPO_PATH && docker compose -f docker-compose.node2-observability.yml up -d" "node2"

    # Start node0 (demo services)
    echo -e "${YELLOW}Starting demo services on node0...${NC}"
    run_on_node $NODE0_IP "cd $REPO_PATH && docker compose -f docker-compose.node0-demo.yml up -d" "node0"

    echo -e "${GREEN}=== All services started ===${NC}"
    echo ""
    echo "Access points:"
    echo "  Frontend:         http://$NODE0_IP:8080"
    echo "  Envoy Admin:      http://$NODE0_IP:10000"
    echo "  Load Gen UI:      http://$NODE3_IP:8089"
    echo "  Grafana (orig):   http://$NODE2_IP:3000"
    echo "  Grafana (gent):   http://$NODE2_IP:3001"
    echo "  Prometheus:       http://$NODE2_IP:9090"
}

stop() {
    local target=${1:-}

    stop_node() {
        local n=$1
        local ip=$(get_node_ip "$n")
        local compose_file
        case $n in
            0) compose_file="docker-compose.node0-demo.yml" ;;
            1) compose_file="docker-compose.node1-collector.yml" ;;
            2) compose_file="docker-compose.node2-observability.yml" ;;
            3) compose_file="docker-compose.node3-kafka.yml" ;;
        esac
        run_on_node "$ip" "cd $REPO_PATH && docker compose -f $compose_file down --remove-orphans" "node$n"
    }

    if [ -n "$target" ]; then
        echo -e "${GREEN}=== Stopping services on node$target ===${NC}"
        stop_node "$target"
    else
        echo -e "${GREEN}=== Stopping all services ===${NC}"
        stop_node 0 &
        stop_node 1 &
        stop_node 2 &
        stop_node 3 &
        wait
    fi

    echo -e "${GREEN}Services stopped${NC}"
}

restart() {
    local node=$1
    local service=${2:-}
    local compose_file
    local node_ip

    case $node in
        0) node_ip=$NODE0_IP; compose_file="docker-compose.node0-demo.yml" ;;
        1) node_ip=$NODE1_IP; compose_file="docker-compose.node1-collector.yml" ;;
        2) node_ip=$NODE2_IP; compose_file="docker-compose.node2-observability.yml" ;;
        3) node_ip=$NODE3_IP; compose_file="docker-compose.node3-kafka.yml" ;;
        *)
            echo "Usage: $0 restart <0|1|2|3> [service]"
            exit 1
            ;;
    esac

    if [ -n "$service" ]; then
        echo -e "${GREEN}=== Restarting $service on node$node ===${NC}"
        run_on_node $node_ip "cd $REPO_PATH && docker compose -f $compose_file restart $service" "node$node"
    else
        echo -e "${GREEN}=== Restarting all services on node$node ===${NC}"
        run_on_node $node_ip "cd $REPO_PATH && docker compose -f $compose_file restart" "node$node"
    fi
}

status() {
    local target=${1:-}

    local -a node_list
    if [ -n "$target" ]; then
        node_list=("node${target}:$(get_node_ip "$target")")
        echo -e "${GREEN}=== Checking status on node$target ===${NC}"
    else
        node_list=("node0:$NODE0_IP" "node1:$NODE1_IP" "node2:$NODE2_IP" "node3:$NODE3_IP")
        echo -e "${GREEN}=== Checking status on all nodes ===${NC}"
    fi

    for node_info in "${node_list[@]}"; do
        node_name="${node_info%%:*}"
        node_ip="${node_info##*:}"
        echo ""
        echo -e "${YELLOW}=== $node_name ($node_ip) ===${NC}"
        ssh $SSH_OPTS $SSH_USER@$node_ip "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null || echo "Failed to connect"
    done

    # Check telemetry storage on node1 (only when showing all or node1)
    if [ -z "$target" ] || [ "$target" = "1" ]; then
        echo ""
        echo -e "${YELLOW}=== Telemetry storage on node1 ===${NC}"
        ssh $SSH_OPTS $SSH_USER@$NODE1_IP "du -sh /data/otel/*/ 2>/dev/null || echo 'No data yet'"
    fi
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
        3)
            ssh $SSH_OPTS $SSH_USER@$NODE3_IP "cd $REPO_PATH && docker compose -f docker-compose.node3-kafka.yml logs -f --tail=100"
            ;;
        *)
            echo "Usage: $0 logs <0|1|2|3>"
            exit 1
            ;;
    esac
}

collect_telemetry() {
    echo -e "${GREEN}=== Collecting telemetry from node1 ===${NC}"

    local output_dir="./collected-telemetry-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$output_dir"

    # Compress and download each telemetry type (use sudo tar to avoid permission issues)
    for type in traces metrics logs; do
        echo -e "${YELLOW}Compressing $type on node1...${NC}"
        if ssh $SSH_OPTS $SSH_USER@$NODE1_IP "sudo rm -f /tmp/otel-${type}.tar.gz && cd /data/otel && sudo tar czf /tmp/otel-${type}.tar.gz ${type}/ 2>/dev/null; rc=\$?; [ \$rc -eq 0 ] || [ \$rc -eq 1 ]" \
            && scp $SSH_OPTS "$SSH_USER@$NODE1_IP:/tmp/otel-${type}.tar.gz" "$output_dir/"; then
            ssh $SSH_OPTS $SSH_USER@$NODE1_IP "sudo rm -f /tmp/otel-${type}.tar.gz"
            echo -e "${GREEN}  $type: $(du -sh "$output_dir/otel-${type}.tar.gz" | cut -f1)${NC}"
        else
            echo "  No $type files found"
        fi
    done

    # Show summary
    echo ""
    echo -e "${GREEN}Downloaded telemetry:${NC}"
    ls -lh "$output_dir/"*.tar.gz 2>/dev/null || echo "  (none)"
    echo ""
    echo "Total size: $(du -sh "$output_dir" | cut -f1)"
    echo "Output directory: $output_dir"
    echo "Extract with: tar xzf otel-traces.tar.gz"
}

reset_telemetry() {
    local force=${1:-}
    echo -e "${GREEN}=== Resetting telemetry data on node1 ===${NC}"

    # Check current data
    echo -e "${YELLOW}Current telemetry data:${NC}"
    ssh $SSH_OPTS $SSH_USER@$NODE1_IP "du -sh /data/otel/*/ 2>/dev/null || echo '  (none)'"

    if [ "$force" != "-y" ]; then
        read -p "Delete all telemetry files (traces, metrics, logs)? (y/N) " confirm
        if [ "$confirm" != "y" ]; then
            echo "Aborted"
            return
        fi
    fi

    ssh $SSH_OPTS $SSH_USER@$NODE1_IP "sudo find /data/otel -name '*.json' -delete"
    echo -e "${GREEN}Telemetry data cleared${NC}"
}

monitor() {
    local node="${1:-all}"
    local watch_mode="${2:-}"

    local stats_cmd="docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}'"

    # Build node list
    local -a nodes
    case $node in
        0) nodes=("node0:$NODE0_IP") ;;
        1) nodes=("node1:$NODE1_IP") ;;
        2) nodes=("node2:$NODE2_IP") ;;
        3) nodes=("node3:$NODE3_IP") ;;
        all)
            nodes=("node0:$NODE0_IP" "node1:$NODE1_IP" "node2:$NODE2_IP" "node3:$NODE3_IP")
            ;;
        -w)
            # handle: monitor -w (no node specified)
            nodes=("node0:$NODE0_IP" "node1:$NODE1_IP" "node2:$NODE2_IP" "node3:$NODE3_IP")
            watch_mode="-w"
            ;;
        *)
            echo "Usage: $0 monitor [0|1|2|3] [-w]"
            exit 1
            ;;
    esac

    collect_stats() {
        for node_info in "${nodes[@]}"; do
            local name="${node_info%%:*}"
            local ip="${node_info##*:}"
            echo -e "${YELLOW}=== $name ($ip) ===${NC}"
            ssh $SSH_OPTS $SSH_USER@$ip "$stats_cmd" 2>/dev/null || echo "Failed to connect"
            echo ""
        done
    }

    if [ "$watch_mode" = "-w" ]; then
        echo -e "${GREEN}=== Monitoring containers (Ctrl+C to stop) ===${NC}"
        while true; do
            clear
            echo -e "${GREEN}=== Container Resource Usage ($(date '+%H:%M:%S')) ===${NC}"
            echo ""
            collect_stats
            sleep 5
        done
    else
        echo -e "${GREEN}=== Container Resource Usage ===${NC}"
        echo ""
        collect_stats
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

    echo "Cleaning telemetry data on node1..."
    ssh $SSH_OPTS $SSH_USER@$NODE1_IP "sudo rm -rf /data/otel/traces/* /data/otel/metrics/* /data/otel/logs/*"

    echo -e "${GREEN}Cleanup complete${NC}"
}

ping_all() {
    local target=${1:-}

    local -a node_list
    if [ -n "$target" ]; then
        node_list=("node${target}:$(get_node_ip "$target")")
    else
        node_list=("node0:$NODE0_IP" "node1:$NODE1_IP" "node2:$NODE2_IP" "node3:$NODE3_IP")
    fi

    echo -e "${GREEN}=== Checking node status ===${NC}"
    for node_info in "${node_list[@]}"; do
        node_name="${node_info%%:*}"
        node_ip="${node_info##*:}"
        if ssh $SSH_OPTS -o ConnectTimeout=5 $SSH_USER@$node_ip "uptime" 2>/dev/null; then
            echo -e "${GREEN}$node_name ($node_ip): reachable${NC}"
        else
            echo -e "${RED}$node_name ($node_ip): unreachable${NC}"
        fi
    done
}

reboot_all() {
    local target=${1:-}
    echo -e "${YELLOW}This will reboot ${target:+node$target}${target:-all CloudLab nodes}.${NC}"
    read -p "Continue? (y/N) " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        return
    fi
    run_on_nodes "sudo reboot" "$target" || true
    echo -e "${GREEN}Reboot command sent${NC}"
}

# Main
case "${1:-}" in
    upgrade)
        upgrade "${2:-}"
        ;;
    docker)
        install_docker "${2:-}"
        ;;
    config)
        config_limits "${2:-}"
        ;;
    sync)
        sync_repo "${2:-}"
        ;;
    build-gent)
        build_gent
        ;;
    deploy)
        deploy "${2:-}"
        ;;
    start)
        start
        ;;
    stop)
        stop "${2:-}"
        ;;
    restart)
        restart "${2:-}" "${3:-}"
        ;;
    status)
        status "${2:-}"
        ;;
    logs)
        logs "${2:-}"
        ;;
    collect)
        collect_telemetry
        ;;
    reset-telemetry)
        reset_telemetry "${2:-}"
        ;;
    monitor)
        monitor "${2:-all}" "${3:-}"
        ;;
    clean)
        clean
        ;;
    terminfo)
        copy_terminfo "${2:-}"
        ;;
    ping)
        ping_all "${2:-}"
        ;;
    reboot)
        reboot_all "${2:-}"
        ;;
    ssh)
        _ssh_node=$2
        node_ip=$(get_node_ip "$_ssh_node")
        shift 2
        run_on_node "$node_ip" "cd $REPO_PATH && $*" "node$_ssh_node"
        ;;
    *)
        usage
        exit 1
        ;;
esac
