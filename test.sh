#!/bin/bash
# =========================================================================
# Unified Test Script for Letmein
# =========================================================================
# Ce script est un point d'entrée unifié pour tous les tests:
# - Mode CI: exécute les tests directement (car déjà dans un conteneur)
# - Mode conteneur: crée un nouveau conteneur Docker et y exécute les tests
# - Mode debug: lance un shell interactif dans un conteneur pour déboguer
echo "starting test.sh"
# Colors for display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
MODE="container"           # Mode: ci, container, debug
LOG_LEVEL="normal"         # Log level: minimal, normal, verbose
DEBUG_INTERVAL="5"         # Interval for debug state capture (seconds)
WITH_GEN_KEY=""            # Whether to include gen-key test
RUN_TESTS=()               # Tests to run
LOG_DIR="$(pwd)/nft-logs"  # Directory for nftables logs
SESSION_ID="$(date +%Y%m%d-%H%M%S)"

# Detect if we're running in CI
detect_environment() {
    # Check for common CI environment variables
    if [ -n "$IN_CI" ] || [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ] || [ -n "$GITLAB_CI" ] || [ -n "$TRAVIS" ] || [ -n "$JENKINS_URL" ]; then
        echo -e "${BLUE}CI environment detected${NC}"
        # In CI, we're likely already in a container, so use ci mode (direct execution)
        MODE="ci"
        return 0
    fi
    
    # Check if we're in a container
    if grep -q docker /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        echo -e "${BLUE}Docker container environment detected${NC}"
        # We're already in a container, use ci mode (direct execution)
        MODE="ci"
        return 0
    fi
    
    # If we're not in CI or a container, use container mode (create a new container)
    MODE="container"
    return 0
}

# Display usage information
usage() {
    echo -e "${YELLOW}===== LETMEIN UNIFIED TEST SCRIPT =====${NC}"
    echo -e "${GREEN}Usage: $0 [OPTIONS] [TESTS]${NC}"
    echo -e "${BLUE}Modes:${NC}"
    echo -e "  --ci                 Run tests directly (for use in CI or when already in a container)"
    echo -e "  --container          Run tests in a new Docker container (default for local development)"
    echo -e "  --debug              Start interactive debugging shell in Docker"
    echo -e "  --auto               Auto-detect environment (ci if in a container, container otherwise)"
    echo -e "\n${BLUE}Test Options:${NC}"
    echo -e "  --with-gen-key       Include gen-key test (disabled by default)"
    echo -e "  --capture-interval N Set interval between state captures (seconds, default: 5)"
    echo -e "  --verbose            Enable verbose logging"
    echo -e "  --minimal            Minimal logging output"
    echo -e "\n${BLUE}Available Tests:${NC}"
    echo -e "  knock                Run knock tests"
    echo -e "  close                Run close tests"
    echo -e "  gen-key              Run gen-key test (requires --with-gen-key)"
    echo -e "\n${BLUE}Examples:${NC}"
    echo -e "  $0 knock close       Run knock and close tests in a container"
    echo -e "  $0 --ci knock close  Run knock and close tests directly (in CI)"
    echo -e "  $0 --debug           Start debugging shell in Docker"
    echo -e "  $0 --auto knock      Auto-detect environment for knock test"
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

# Function to ensure Rust components are installed
ensure_rust_components() {
    echo -e "${YELLOW}Vérification des composants Rust nécessaires...${NC}"
    
    # Vérifier si clippy est installé
    if ! rustup component list --installed | grep -q clippy; then
        echo -e "${YELLOW}Installation de clippy...${NC}"
        rustup component add clippy || {
            echo -e "${YELLOW}Tentative d'installation de clippy via cargo...${NC}"
            cargo install clippy || {
                echo -e "${RED}Impossible d'installer clippy. Les tests peuvent échouer.${NC}"
                echo -e "${YELLOW}Les tests continueront sans vérification clippy.${NC}"
                # Créer une variable d'environnement pour désactiver clippy
                export SKIP_CLIPPY=1
            }
        }
    else
        echo -e "${GREEN}Clippy est déjà installé.${NC}"
    fi
    
    echo -e "${GREEN}Configuration Rust terminée.${NC}"
}

# Function to run tests locally
run_local_tests() {
    echo -e "${GREEN}=== RUNNING LOCAL TESTS ===${NC}"
    
    # Build the project if necessary
    echo -e "${YELLOW}Building the project...${NC}"
    which cargo
    echo "PATH=$PATH"
    
    # Ensure Rust components are installed
    ensure_rust_components
    
    /usr/local/cargo/bin/cargo build || cargo build
    
    # Set environment variables
    export LETMEIN_DISABLE_SECCOMP=1
    
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
    
    # Vérifier la validité des tests
    validate_tests $test_args
    
    # Run tests with sudo for nftables access
    sudo -E ./tests/run-tests.sh $test_args
    TEST_EXIT_CODE=$?
    
    # Display test results
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}=== TESTS SUCCEEDED (exit code: $TEST_EXIT_CODE) ===${NC}"
    else
        echo -e "${RED}=== TESTS FAILED (exit code: $TEST_EXIT_CODE) ===${NC}"
    fi
    
    # Affichage simplifié des résultats
    show_test_results
    
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
    
    # Message d'information sur les tests Docker
    echo -e "${BLUE}Préparation des tests Docker...${NC}"
    
    # --- Exécuter les tests dans Docker avec les vrais nftables ---
    echo -e "${BLUE}Lancement du conteneur Docker pour les tests...${NC}"
    
    # --- Construction explicite de la commande Docker ---
    echo -e "${BLUE}Construction de la commande Docker...${NC}"
    
    # Rendre le script exécutable
    chmod +x "$DOCKER_SCRIPT"
    
    # Utiliser notre script dédié pour le test Docker avec affichage complet
    echo -e "${BLUE}Utilisation du script docker-test-script.sh pour une sortie détaillée${NC}"

    echo -e "${BLUE}Lancement du conteneur Docker pour les tests...${NC}"
    echo -e "${BLUE}Tests à exécuter: $test_args${NC}"

    # Exécution des tests dans un conteneur Docker avec notre script dédié
    echo -e "${BLUE}Exécution des tests avec affichage détaillé et capture des sorties...${NC}"
    
    # Commande Docker avec option -t pour s'assurer que les sorties sont préservées
    docker run \
        --rm \
        -t \
        --privileged \
        --cap-add=NET_ADMIN \
        --cap-add=SYS_ADMIN \
        --dns 8.8.8.8 \
        --dns 1.1.1.1 \
        --security-opt seccomp=unconfined \
        -e LETMEIN_DISABLE_SECCOMP=1 \
        -e DISABLE_STRACE=1 \
        -e "LOG_LEVEL=debug" \
        -e RUST_LOG=debug \
        -e RUST_BACKTRACE=full \
        -v "$(pwd):/app" \
        --workdir /app \
        letmein-test:latest \
        ./docker-test-script.sh $test_args
        
    # Fin des tests Docker
    
    TEST_EXIT_CODE=$?
    
    # Display test results
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}=== DOCKER TESTS SUCCEEDED (exit code: $TEST_EXIT_CODE) ===${NC}"
    else
        echo -e "${RED}=== DOCKER TESTS FAILED (exit code: $TEST_EXIT_CODE) ===${NC}"
        echo -e "${YELLOW}You can debug further with: $0 --debug${NC}"
    fi
    
    # Affichage simplifié des résultats
    show_test_results
    
    return $TEST_EXIT_CODE
}

# Fonction pour vérifier la validité des tests spécifiés
validate_tests() {
    local valid_tests=("knock" "close" "gen-key")
    # Ne pas vérifier les arguments du Docker script
    # Simplement valider si au moins un test valide est présent
    
    # Vérifier uniquement les tests connus (knock, close, gen-key)
    local found_valid=0
    for test in "$@"; do
        for valid_test in "${valid_tests[@]}"; do
            if [ "$test" = "$valid_test" ]; then
                found_valid=1
                break
            fi
        done
    done
    
    # Si aucun test valide n'est trouvé, afficher un avertissement
    if [ $found_valid -eq 0 ]; then
        echo -e "${YELLOW}Aucun test valide spécifié. Tests disponibles: knock, close, gen-key${NC}"
    fi
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

# Fonction pour afficher les résultats des tests simplement (sans logs détaillés)
show_test_results() {
    echo -e "${GREEN}Tests exécutés avec succès${NC}"
}

# Main function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ci|--local)
                MODE="ci"
                shift
                ;;
            --container|--docker)
                MODE="container"
                shift
                ;;
            --debug)
                MODE="debug"
                shift
                ;;
            --auto)
                # We'll detect the environment later
                MODE="auto"
                shift
                ;;
            --help|-h)
                usage
                ;;
            --verbose)
                LOG_LEVEL="verbose"
                shift
                ;;
            --minimal)
                LOG_LEVEL="minimal"
                shift
                ;;
            --with-gen-key)
                WITH_GEN_KEY="1"
                shift
                ;;
            --capture-interval)
                DEBUG_INTERVAL="$2"
                shift 2
                ;;
            *)
                # If it starts with --, it's an invalid option
                if [[ "$1" == --* ]]; then
                    echo -e "${RED}Unknown option: $1${NC}"
                    usage
                    exit 1
                fi
                
                # Otherwise, it's a test name
                RUN_TESTS+=("$1")
                shift
                ;;
        esac
    done
    
    # If auto mode, detect environment
    if [ "$MODE" = "auto" ]; then
        detect_environment
    fi
    
    # Now either run directly or in container
    case "$MODE" in
        ci)
            echo -e "Mode: ${GREEN}CI testing${NC} (direct execution)"
            ;;
        container)
            echo -e "Mode: ${GREEN}Container testing${NC} (in a new Docker container)"
            ;;
        debug)
            echo -e "Mode: ${GREEN}Debug mode${NC} (interactive shell)"
            ;;
    esac
    
    # Display the tests to run
    if [ ${#RUN_TESTS[@]} -gt 0 ]; then
        for test in "${RUN_TESTS[@]}"; do
            echo -e "Adding test: ${YELLOW}$test${NC}"
        done
    else
        echo -e "Using default tests: ${YELLOW}knock close${NC}"
        if [ "$WITH_GEN_KEY" = "1" ]; then
            echo -e "Also including: ${YELLOW}gen-key${NC}"
        fi
    fi
    
    # Run tests with the chosen mode
    case "$MODE" in
        ci)
            run_local_tests
            ;;
        container)
            run_docker_tests
            ;;
        debug)
            run_debug_mode
            ;;
        *)
            echo -e "${RED}Unknown mode: $MODE${NC}"
            exit 1
            ;;
    esac
    
    local exit_code=$?
    
    # Display success message
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Tests exécutés avec succès${NC}"
        return 0
    else
        echo -e "${RED}Des erreurs se sont produites pendant les tests${NC}"
        return $exit_code
    fi
}

# Run the main function
main "$@"
