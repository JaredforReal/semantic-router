#!/bin/bash
# Quick start script for LLM Katan multi-instance setup
# This script demonstrates running multiple llm-katan instances
# simulating different LLM providers using the same tiny model
#
# Usage:
#   ./quick-start-llm-katan.sh [start|stop|status|test]

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS_FILE="$SCRIPT_DIR/llm-katan.pids"
LOG_DIR="$SCRIPT_DIR/logs"

# Model configurations: "port:model:served_name:temp:max_tokens"
declare -a INSTANCES=(
    "8100:Qwen/Qwen3-0.6B:gpt-3.5-turbo:0.7:512"
    "8101:Qwen/Qwen3-0.6B:claude-3-haiku:0.5:768"
    "8102:Qwen/Qwen3-0.6B:Meta-Llama-3.1-8B:0.9:1024"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}ℹ${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

check_requirements() {
    log_info "Checking requirements..."
    
    # Check if llm-katan is installed
    if ! command -v llm-katan &> /dev/null; then
        log_error "llm-katan not found. Installing..."
        pip install llm-katan
    else
        log_success "llm-katan is installed"
    fi
    
    # Check HuggingFace token
    if [ -z "$HUGGINGFACE_HUB_TOKEN" ]; then
        log_warn "HUGGINGFACE_HUB_TOKEN not set. You may encounter rate limits."
        log_warn "Get your token from: https://huggingface.co/settings/tokens"
        log_warn "Then run: export HUGGINGFACE_HUB_TOKEN=your_token"
    else
        log_success "HuggingFace token found"
    fi
}

check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

start_instances() {
    log_info "Starting LLM Katan instances..."
    
    # Check requirements
    check_requirements
    
    # Create logs directory
    mkdir -p "$LOG_DIR"
    
    # Remove old PID file
    rm -f "$PIDS_FILE"
    
    # Start each instance
    for instance in "${INSTANCES[@]}"; do
        IFS=':' read -r port model served_name temp max_tokens <<< "$instance"
        
        # Check if port is available
        if ! check_port "$port"; then
            log_error "Port $port is already in use. Skipping..."
            continue
        fi
        
        log_info "Starting instance on port $port..."
        log_info "  Model: $model"
        log_info "  Served as: $served_name"
        log_info "  Temperature: $temp"
        log_info "  Max tokens: $max_tokens"
        
        # Start instance in background
        llm-katan \
            --model "$model" \
            --served-model-name "$served_name" \
            --port "$port" \
            --host "127.0.0.1" \
            --max-tokens "$max_tokens" \
            --temperature "$temp" \
            --log-level INFO \
            > "$LOG_DIR/llm-katan-$port.log" 2>&1 &
        
        local pid=$!
        echo "$pid" >> "$PIDS_FILE"
        log_success "Instance started on port $port (PID: $pid)"
        
        # Brief pause between starts
        sleep 2
    done
    
    log_success "All instances started!"
    echo ""
    log_info "Waiting for instances to be ready..."
    sleep 30
    
    # Show status
    show_status
}

stop_instances() {
    log_info "Stopping LLM Katan instances..."
    
    if [ ! -f "$PIDS_FILE" ]; then
        log_warn "No PID file found. Instances may not be running."
        return
    fi
    
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping process $pid..."
            kill "$pid" 2>/dev/null || true
            log_success "Process $pid stopped"
        else
            log_warn "Process $pid not found"
        fi
    done < "$PIDS_FILE"
    
    rm -f "$PIDS_FILE"
    log_success "All instances stopped"
}

show_status() {
    log_info "LLM Katan Instances Status:"
    echo ""
    
    for instance in "${INSTANCES[@]}"; do
        IFS=':' read -r port model served_name temp max_tokens <<< "$instance"
        
        # Check if port is listening
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            local pid=$(lsof -Pi :$port -sTCP:LISTEN -t)
            log_success "Port $port: RUNNING (PID: $pid, Model: $served_name)"
            
            # Try health check
            if curl -s -f "http://127.0.0.1:$port/health" > /dev/null 2>&1; then
                echo -e "  ${GREEN}└─${NC} Health check: OK"
            else
                echo -e "  ${YELLOW}└─${NC} Health check: NOT READY (model loading...)"
            fi
        else
            log_error "Port $port: NOT RUNNING (Model: $served_name)"
        fi
        echo ""
    done
    
    log_info "Endpoints:"
    for instance in "${INSTANCES[@]}"; do
        IFS=':' read -r port model served_name temp max_tokens <<< "$instance"
        echo -e "  ${BLUE}http://127.0.0.1:$port${NC} → $served_name"
    done
}

test_instances() {
    log_info "Testing LLM Katan instances..."
    echo ""
    
    for instance in "${INSTANCES[@]}"; do
        IFS=':' read -r port model served_name temp max_tokens <<< "$instance"
        
        log_info "Testing $served_name on port $port..."
        
        # Test health endpoint
        if curl -s -f "http://127.0.0.1:$port/health" > /dev/null 2>&1; then
            log_success "Health check: OK"
        else
            log_error "Health check: FAILED"
            continue
        fi
        
        # Test models endpoint
        local model_id=$(curl -s "http://127.0.0.1:$port/v1/models" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ "$model_id" == "$served_name" ]; then
            log_success "Models endpoint: OK (returns $model_id)"
        else
            log_error "Models endpoint: FAILED (expected $served_name, got $model_id)"
        fi
        
        # Test chat completions
        local response=$(curl -s -X POST "http://127.0.0.1:$port/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{
                "model": "'"$served_name"'",
                "messages": [{"role": "user", "content": "Say hello!"}],
                "max_tokens": 20
            }')
        
        if echo "$response" | grep -q '"content"'; then
            log_success "Chat completions: OK"
            local content=$(echo "$response" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
            echo -e "  ${GREEN}└─${NC} Response: ${content:0:50}..."
        else
            log_error "Chat completions: FAILED"
        fi
        
        # Test metrics endpoint
        if curl -s -f "http://127.0.0.1:$port/metrics" | grep -q "llm_katan"; then
            log_success "Metrics endpoint: OK"
        else
            log_error "Metrics endpoint: FAILED"
        fi
        
        echo ""
    done
    
    log_success "Testing complete!"
}

show_usage() {
    cat << EOF
${GREEN}LLM Katan Quick Start Script${NC}

Usage: $0 [command]

Commands:
  ${BLUE}start${NC}    Start all LLM Katan instances
  ${BLUE}stop${NC}     Stop all LLM Katan instances
  ${BLUE}status${NC}   Show status of all instances
  ${BLUE}test${NC}     Test all instances (health, models, chat, metrics)
  ${BLUE}logs${NC}     Show logs for all instances
  ${BLUE}help${NC}     Show this help message

Environment Variables:
  HUGGINGFACE_HUB_TOKEN  Your HuggingFace token (recommended)

Examples:
  # Start all instances
  $0 start

  # Check status
  $0 status

  # Run tests
  $0 test

  # Stop all instances
  $0 stop

Instances Configuration:
EOF
    for instance in "${INSTANCES[@]}"; do
        IFS=':' read -r port model served_name temp max_tokens <<< "$instance"
        echo "  Port $port: $served_name (temp=$temp, max=$max_tokens)"
    done
}

show_logs() {
    if [ ! -d "$LOG_DIR" ]; then
        log_error "No logs directory found"
        return
    fi
    
    log_info "Recent logs from all instances:"
    echo ""
    
    for instance in "${INSTANCES[@]}"; do
        IFS=':' read -r port model served_name temp max_tokens <<< "$instance"
        local log_file="$LOG_DIR/llm-katan-$port.log"
        
        if [ -f "$log_file" ]; then
            echo -e "${BLUE}=== Port $port ($served_name) ===${NC}"
            tail -n 10 "$log_file"
            echo ""
        fi
    done
}

# Main
case "${1:-}" in
    start)
        start_instances
        ;;
    stop)
        stop_instances
        ;;
    status)
        show_status
        ;;
    test)
        test_instances
        ;;
    logs)
        show_logs
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
