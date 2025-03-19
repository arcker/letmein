#!/bin/bash
# =========================================================================
# Unified Test Script for Letmein
# =========================================================================
# Ce script est un point d'entrée unifié pour tous les tests:
# - Tests locaux (anciennement run-tests.sh)
# - Tests Docker (anciennement docker-test.sh)
# - Débogage avancé (anciennement debug-test.sh)

# Colors for display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
MODE="local"               # Mode: local, docker, debug
LOG_LEVEL="normal"         # Log level: minimal, normal, verbose
DEBUG_INTERVAL="5"         # Interval for debug state capture (seconds)
WITH_GEN_KEY=""           # Whether to include gen-key test
RUN_TESTS=()              # Tests to run
LOG_DIR="$(pwd)/nft-logs"  # Directory for nftables logs
SESSION_ID="$(date +%Y%m%d-%H%M%S)"

# Display usage information
usage() {
    echo -e "${YELLOW}===== LETMEIN UNIFIED TEST SCRIPT =====${NC}"
    echo -e "${GREEN}Usage: $0 [OPTIONS] [TESTS]${NC}"
    echo -e "${BLUE}Modes:${NC}"
    echo -e "  --local              Run tests locally (default)"
    echo -e "  --docker             Run tests in Docker container"
    echo -e "  --debug              Start interactive debugging shell in Docker"
    echo -e "\n${BLUE}Test Options:${NC}"
    echo -e "  # Option --real retirée car on utilise toujours les vrais nftables maintenant"
    echo -e "  --with-gen-key       Include gen-key test (disabled by default)"
    echo -e "  --capture-interval N Set interval between state captures (seconds, default: 5)"
    echo -e "  --verbose            Enable verbose logging"
    echo -e "  --minimal            Minimal logging output"
    echo -e "\n${BLUE}Available Tests:${NC}"
    echo -e "  knock                Run knock tests"
    echo -e "  close                Run close tests"
    echo -e "  gen-key              Run gen-key test (requires --with-gen-key)"
    echo -e "\n${BLUE}Examples:${NC}"
    echo -e "  $0 knock close       Run knock and close tests locally with mock nftables"
    echo -e "  $0 --docker --real   Run all tests in Docker with real nftables"
    echo -e "  $0 --debug           Start debugging shell in Docker"
    echo -e "  $0 --with-gen-key gen-key  Run gen-key test locally"
    echo -e "\n${YELLOW}Note:${NC} If no test is specified, all appropriate tests will run"
    echo -e "      (knock and close by default, plus gen-key if --with-gen-key is used)"
    exit 0
}

# Function to capture nftables state
capture_nft_state() {
    local state_name="$1"
    local timestamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$LOG_DIR"
    local state_file="$LOG_DIR/nft-state-$state_name-$timestamp.log"
    
    echo -e "${BLUE}Capturing nftables state: $state_name...${NC}"
    
    echo "== nftables state: $state_name ==" > "$state_file"
    echo "Timestamp: $(date)" >> "$state_file"
    echo "== Command: nft list ruleset ==" >> "$state_file"
    
    if [ "$MODE" = "docker" ]; then
        # Dans Docker nous avons probablement des droits suffisants
        echo "Exécution de 'nft list ruleset' dans Docker..." >> "$state_file"
        nft list ruleset >> "$state_file" 2>&1
        if [ $? -ne 0 ]; then
            echo "Error: nft command failed with exit code $?" >> "$state_file"
            echo "Commande nftables échouée dans Docker" 
        fi
    else
        # En local, nous avons peut-être besoin de sudo
        echo "Exécution de 'sudo nft list ruleset' en local..." >> "$state_file"
        sudo nft list ruleset >> "$state_file" 2>&1 
        if [ $? -ne 0 ]; then
            echo "Error: sudo nft command failed with exit code $?" >> "$state_file"
            echo "Commande sudo nftables échouée en local"
        fi
    fi

    if [ "$LOG_LEVEL" = "verbose" ]; then
        echo -e "${GREEN}State captured to: $state_file${NC}"
    fi
}

# Function to run a background process that periodically captures the state
start_periodic_capture() {
    if [ "$LOG_LEVEL" = "minimal" ]; then
        return 0  # Skip periodic capture in minimal mode
    fi
    
    echo -e "${BLUE}Starting periodic nftables state capture (every $DEBUG_INTERVAL seconds)...${NC}"
    
    # Start background process for periodic capture
    (
        capture_count=0
        while true; do
            capture_count=$((capture_count + 1))
            capture_nft_state "periodic-$capture_count"
            sleep $DEBUG_INTERVAL
        done
    ) &
    
    CAPTURE_PID=$!
    echo -e "${GREEN}Periodic capture started with PID: $CAPTURE_PID${NC}"
    echo $CAPTURE_PID > "$LOG_DIR/capture-pid-$SESSION_ID.txt"
}

# Function to stop the periodic capture
stop_periodic_capture() {
    if [ -f "$LOG_DIR/capture-pid-$SESSION_ID.txt" ]; then
        CAPTURE_PID=$(cat "$LOG_DIR/capture-pid-$SESSION_ID.txt")
        echo -e "${BLUE}Stopping periodic capture (PID: $CAPTURE_PID)${NC}"
        kill $CAPTURE_PID 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Unable to kill capture process (PID: $CAPTURE_PID)${NC}"
        fi
        rm "$LOG_DIR/capture-pid-$SESSION_ID.txt"
    else
        echo -e "${YELLOW}No active periodic capture found for this session${NC}"
    fi
}

# Function to run tests locally
run_local_tests() {
    echo -e "${GREEN}=== RUNNING LOCAL TESTS ===${NC}"
    
    # Capture initial state
    capture_nft_state "initial"
    
    # Start periodic capture if in debug mode
    if [ "$LOG_LEVEL" = "verbose" ]; then
        start_periodic_capture
    fi
    
    # Build the project if necessary
    echo -e "${YELLOW}Building the project...${NC}"
    cargo build
    
    # Set environment variables
    export LETMEIN_DISABLE_SECCOMP=1
    # Nous utilisons toujours les vrais nftables maintenant
    unset MOCK_NFTABLES
    
    # Capture state before tests
    capture_nft_state "before-tests"
    
    # Prepare test arguments
    local test_args=""
    if [ ${#RUN_TESTS[@]} -gt 0 ]; then
        test_args="${RUN_TESTS[*]}"
    else
        # Default tests
        if [ "$WITH_GEN_KEY" = "1" ]; then
            test_args="knock close gen-key"
        else
            test_args="knock close"
        fi
    fi
    
    echo -e "${YELLOW}Running tests: $test_args${NC}"
    
    # Run tests with sudo for nftables access
    sudo -E ./tests/run-tests.sh $test_args
    TEST_EXIT_CODE=$?
    
    # Capture state after tests
    capture_nft_state "after-tests"
    
    # Stop periodic capture
    if [ "$LOG_LEVEL" = "verbose" ]; then
        stop_periodic_capture
    fi
    
    # Display test results
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}=== TESTS SUCCEEDED (exit code: $TEST_EXIT_CODE) ===${NC}"
    else
        echo -e "${RED}=== TESTS FAILED (exit code: $TEST_EXIT_CODE) ===${NC}"
    fi
    
    # Display debug logs information
    display_logs_info
    
    return $TEST_EXIT_CODE
}

# Function to run tests in Docker
run_docker_tests() {
    echo -e "${GREEN}=== RUNNING DOCKER TESTS ===${NC}"
    
    # Create Docker image
    echo -e "${YELLOW}Creating Docker image for tests...${NC}"
    docker build -t letmein-test -f Dockerfile.test .
    
    # Prepare test arguments
    local test_args=""
    if [ ${#RUN_TESTS[@]} -gt 0 ]; then
        test_args="${RUN_TESTS[*]}"
    else
        # Default tests
        if [ "$WITH_GEN_KEY" = "1" ]; then
            test_args="knock close gen-key"
        else
            test_args="knock close"
        fi
    fi
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    echo -e "${YELLOW}Running tests in Docker: $test_args${NC}"
    echo -e "${YELLOW}Using real nftables for all tests${NC}"
    
    # Créer un script temporaire pour éviter les problèmes d'interprétation
    DOCKER_SCRIPT="$(mktemp)"
    
    # Écrire le script Docker avec une syntaxe claire
    cat > "$DOCKER_SCRIPT" << 'EOF'
#!/bin/sh

# Configuration stricte pour détecter les erreurs
set -e

# Variables passées par l'environnement
LOG_DIR=${LOG_DIR:-/app/nft-logs}
TEST_ARGS=${TEST_ARGS:-knock close}

# --- Création du répertoire de logs ---
mkdir -p "$LOG_DIR"
echo "Répertoire de logs créé: $LOG_DIR"

# --- Capture de l'état initial ---
echo "=== Capture de l'état initial des règles nftables ==="
nft list ruleset > "$LOG_DIR/nft-state-initial-$(date +%Y%m%d-%H%M%S).log"

# --- Compilation si nécessaire ---
echo "=== Compilation du projet ==="
cargo build
BUILD_RESULT=$?

if [ $BUILD_RESULT -ne 0 ]; then
    echo "ERREUR: Échec de la compilation (code: $BUILD_RESULT)"
    exit $BUILD_RESULT
fi

# --- Capture pré-test ---
echo "=== Capture de l'état des règles nftables avant les tests ==="
nft list ruleset > "$LOG_DIR/nft-state-before-tests-$(date +%Y%m%d-%H%M%S).log"

# --- Exécution des tests ---
echo "=== Exécution des tests: $TEST_ARGS ==="
cd ./tests
./run-tests.sh $TEST_ARGS
TEST_RESULT=$?
cd ..

# --- Capture post-test ---
echo "=== Capture de l'état des règles nftables après les tests ==="
nft list ruleset > "$LOG_DIR/nft-state-after-tests-$(date +%Y%m%d-%H%M%S).log"

# --- Affichage du résumé des logs ---
echo "=== Tests terminés avec le code de sortie: $TEST_RESULT ==="
echo "=== Logs nftables générés: ==="
ls -la "$LOG_DIR/"

# Retourne le statut des tests
exit $TEST_RESULT
EOF

    # Rendre le script exécutable
    chmod +x "$DOCKER_SCRIPT"
    
    # --- Exécuter les tests dans Docker avec les vrais nftables ---
    echo -e "${BLUE}Lancement du conteneur Docker pour les tests...${NC}"
    
    # --- Construction explicite de la commande Docker ---
    echo -e "${BLUE}Construction de la commande Docker...${NC}"
    
    # Construction de la commande Docker de manière plus sécurisée
    # en évitant les problèmes d'expansion de variables
    docker run \
        --rm \
        --privileged \
        --cap-add=NET_ADMIN \
        --cap-add=SYS_ADMIN \
        --dns 8.8.8.8 \
        --dns 1.1.1.1 \
        --security-opt seccomp=unconfined \
        -e LETMEIN_DISABLE_SECCOMP=1 \
        -e DISABLE_STRACE=1 \
        -e "LOG_LEVEL=$LOG_LEVEL" \
        -e RUST_BACKTRACE=0 \
        -e "LOG_DIR=$LOG_DIR" \
        -e "TEST_ARGS=$test_args" \
        -v "$(pwd):/app" \
        -v "$DOCKER_SCRIPT:/run-docker-tests.sh" \
        --workdir /app \
        letmein-test \
        /run-docker-tests.sh
        
    # Nettoyage du script temporaire
    rm -f "$DOCKER_SCRIPT"
    
    TEST_EXIT_CODE=$?
    
    # Display test results
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}=== DOCKER TESTS SUCCEEDED (exit code: $TEST_EXIT_CODE) ===${NC}"
    else
        echo -e "${RED}=== DOCKER TESTS FAILED (exit code: $TEST_EXIT_CODE) ===${NC}"
        echo -e "${YELLOW}You can debug further with: $0 --debug${NC}"
    fi
    
    # Display debug logs information
    display_logs_info
    
    return $TEST_EXIT_CODE
}

# Function to run interactive debug mode in Docker
run_debug_mode() {
    echo -e "${GREEN}=== STARTING INTERACTIVE DEBUG SHELL IN DOCKER ===${NC}"
    echo -e "${YELLOW}Using real nftables for debugging${NC}"
    
    docker build -t letmein-test -f Dockerfile.test .
    
    echo -e "${BLUE}Starting interactive Docker container for debugging...${NC}"
    echo -e "${YELLOW}Use './tests/run-tests.sh <test>' to run specific tests${NC}"
    echo -e "${YELLOW}Use './test.sh --local <test>' to run the local test flow${NC}"
    
    docker run --rm -it \
        --privileged \
        --cap-add=NET_ADMIN \
        --cap-add=SYS_ADMIN \
        --security-opt seccomp=unconfined \
        -e LETMEIN_DISABLE_SECCOMP=1 \
        -e LOG_LEVEL="$LOG_LEVEL" \
        -v "$(pwd):/app" \
        --workdir /app \
        --entrypoint /bin/bash \
        letmein-test
    
    # No exit code check needed as this is interactive
    return 0
}

# Function to display information about logs
display_logs_info() {
    echo -e "${GREEN}=== DEBUG LOGS INFORMATION ===${NC}"
    echo -e "${BLUE}Debug logs are available in: $LOG_DIR${NC}"
    
    # List important log files
    echo -e "${BLUE}Important log files:${NC}"
    ls -la "$LOG_DIR" | grep -E "initial|before-tests|after-tests" | awk '{print $9}' | while read file; do
        echo -e "${YELLOW}- $LOG_DIR/$file${NC}"
    done
    
    # Show current state
    echo -e "\n${GREEN}Current nftables state:${NC}"
    if [ "$MODE" = "docker" ]; then
        echo -e "${YELLOW}(Run with --debug to inspect current state in container)${NC}"
    else
        echo -e "${YELLOW}$(sudo nft list ruleset 2>&1 | head -n 10)${NC}"
        if [ $(sudo nft list ruleset 2>&1 | wc -l) -gt 10 ]; then
            echo -e "${YELLOW}[...] (output truncated, use 'sudo nft list ruleset' for full output)${NC}"
        fi
    fi
    
    # Suggest useful commands
    echo -e "\n${GREEN}Useful commands:${NC}"
    echo -e "${YELLOW}- To view test output: less -R $LOG_DIR/nft-state-after-tests-*.log${NC}"
    echo -e "${YELLOW}- To compare before/after: diff $LOG_DIR/nft-state-before-tests-*.log $LOG_DIR/nft-state-after-tests-*.log${NC}"
}

# Parse command line options
while [ $# -gt 0 ]; do
    case "$1" in
        --local)
            MODE="local"
            echo -e "${YELLOW}Mode: Local testing${NC}"
            ;;
        --docker)
            MODE="docker"
            echo -e "${YELLOW}Mode: Docker testing${NC}"
            ;;
        --debug)
            MODE="debug"
            echo -e "${YELLOW}Mode: Interactive debugging in Docker${NC}"
            ;;
        --real)
            echo -e "${YELLOW}Option --real ignorée: les vrais nftables sont déjà utilisés par défaut${NC}"
            ;;
        --with-gen-key)
            WITH_GEN_KEY="1"
            echo -e "${YELLOW}Including gen-key test${NC}"
            ;;
        --capture-interval)
            shift
            DEBUG_INTERVAL="$1"
            echo -e "${YELLOW}Debug interval: $DEBUG_INTERVAL seconds${NC}"
            ;;
        --verbose)
            LOG_LEVEL="verbose"
            echo -e "${YELLOW}Log level: Verbose${NC}"
            ;;
        --minimal)
            LOG_LEVEL="minimal"
            echo -e "${YELLOW}Log level: Minimal${NC}"
            ;;
        --help)
            usage
            ;;
        knock|close|gen-key)
            RUN_TESTS+=("$1")
            echo -e "${YELLOW}Adding test: $1${NC}"
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
        *)
            RUN_TESTS+=("$1")
            echo -e "${YELLOW}Adding test: $1${NC}"
            ;;
    esac
    shift
done

# Validate test selection
if [[ " ${RUN_TESTS[*]} " =~ " gen-key " ]] && [ "$WITH_GEN_KEY" != "1" ]; then
    echo -e "${RED}The gen-key test was specified but --with-gen-key is not enabled${NC}"
    echo -e "${YELLOW}Use --with-gen-key to run the gen-key test${NC}"
    exit 1
fi

# Run tests based on selected mode
case "$MODE" in
    local)
        run_local_tests
        exit $?
        ;;
    docker)
        run_docker_tests
        exit $?
        ;;
    debug)
        run_debug_mode
        exit $?
        ;;
    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        usage
        ;;
esac
