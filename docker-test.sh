#!/bin/bash

# Colors for display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Options detection
DEBUG_MODE=""
MOCK_NFTABLES="0" # Par défaut, on utilise les vrais nftables
WITH_GEN_KEY=""
SPECIFIC_TESTS=""

# Help message
usage() {
    echo -e "Usage: $0 [OPTIONS] [TESTS]"
    echo -e "Options:"
    echo -e "  --debug           Launch an interactive shell for debugging"
    echo -e "  --MOCK_NFTABLES    Use nftables stub instead of real nftables"
    echo -e "  --with-gen-key    Include the gen-key test (disabled by default)"
    echo -e "  --help            Display this help message"
    echo -e "Available tests:"
    echo -e "  knock             Run only knock tests"
    echo -e "  close             Run only close tests"
    echo -e "  gen-key           Run only the gen-key test (requires --with-gen-key)"
    echo -e "If no test is specified and --with-gen-key is not used,"
    echo -e "the knock and close tests will be run by default."
    exit 0
}

# Parse command line options
TESTS=()
for arg in "$@"; do
    case $arg in
        --debug)
            DEBUG_MODE="1"
            echo -e "${YELLOW}Debug mode enabled${NC}"
            ;;
        --MOCK_NFTABLES)
            MOCK_NFTABLES="1"
            echo -e "${YELLOW}Mock nftables mode enabled${NC}"
            ;;
        --with-gen-key)
            WITH_GEN_KEY="1"
            echo -e "${YELLOW}Gen-key test included${NC}"
            ;;
        --help)
            usage
            ;;
        knock|close|gen-key)
            TESTS+=("$arg")
            ;;
        -*)
            echo -e "${RED}Unknown option: $arg${NC}"
            usage
            ;;
    esac
done

echo -e "${YELLOW}Creating Docker image for tests...${NC}"
docker build -t letmein-test -f Dockerfile.test .

# Exécuter les tests dans Docker
if [ "$DEBUG_MODE" = "1" ]; then
    # Debug mode - launch an interactive shell
    echo -e "${YELLOW}Starting container in interactive mode for debugging...${NC}"
    docker run --rm -it \
        --privileged \
        --cap-add=NET_ADMIN \
        --cap-add=SYS_ADMIN \
        --security-opt seccomp=unconfined \
        -e MOCK_NFTABLES="1" \
        -e LETMEIN_DISABLE_SECCOMP="1" \
        -v "$(pwd):/app" \
        --entrypoint /bin/sh \
        letmein-test
    exit $?
else
    # Determine whether to use the stub or real nftables
    if [ "$MOCK_NFTABLES" = "1" ]; then
        echo -e "${YELLOW}Running tests with nftables stub (MOCK_NFTABLES=1)...${NC}"
    else
        echo -e "${YELLOW}Running tests with real nftables (MOCK_NFTABLES=0)...${NC}"
    fi

    # Determine which tests to run
    if [ ${#TESTS[@]} -gt 0 ]; then
        # Use tests specified on the command line
        TEST_ARGS="${TESTS[*]}"
        echo -e "${YELLOW}Running specified tests: ${TEST_ARGS}${NC}"
    elif [ "$WITH_GEN_KEY" = "1" ]; then
        # Run all tests including gen-key
        TEST_ARGS=""
        echo -e "${YELLOW}All tests will be run, including gen-key${NC}"
    else
        # By default, run only knock and close
        TEST_ARGS="knock close"
        echo -e "${YELLOW}Running default tests (knock and close)${NC}"
    fi
    
    # Check if gen-key is requested without the --with-gen-key option
    if [[ " ${TESTS[*]} " =~ " gen-key " ]] && [ "$WITH_GEN_KEY" != "1" ]; then
        echo -e "${RED}The gen-key test was specified but --with-gen-key is not enabled${NC}"
        echo -e "${YELLOW}Use --with-gen-key to run the gen-key test${NC}"
        exit 1
    fi

    # Prepare environment variables
    # Disable strace when seccomp is disabled to avoid conflicts
    DISABLE_STRACE="1"
    
    # Run the tests
    if [ "$MOCK_NFTABLES" = "1" ]; then
        # Mock mode: pass the MOCK_NFTABLES variable
        docker run --rm \
            --privileged \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_ADMIN \
            --security-opt seccomp=unconfined \
            -e MOCK_NFTABLES=1 \
            -e LETMEIN_DISABLE_SECCOMP=1 \
            -e DISABLE_STRACE="$DISABLE_STRACE" \
            -e RUST_BACKTRACE=0 \
            -e LD_PRELOAD="" \
            -v "$(pwd):/app" \
            --entrypoint /bin/sh \
            letmein-test -c "cd /app && ./debug-test.sh --test \"$TEST_ARGS\" && echo -e '${GREEN}Debug logs have been written to the nft-logs directory${NC}'"
    else
        # Real mode: pass MOCK_NFTABLES=0 explicitly
        docker run --rm \
            --privileged \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_ADMIN \
            --security-opt seccomp=unconfined \
            -e MOCK_NFTABLES=0 \
            -e LETMEIN_DISABLE_SECCOMP=1 \
            -e DISABLE_STRACE="$DISABLE_STRACE" \
            -e RUST_BACKTRACE=0 \
            -e LD_PRELOAD="" \
            -v "$(pwd):/app" \
            --entrypoint /bin/sh \
            letmein-test -c "cd /app && ./debug-test.sh --test \"$TEST_ARGS\" && echo -e '${GREEN}Debug logs have been written to the nft-logs directory${NC}'"
    fi
    
    # Check exit code
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed!${NC}"
        echo -e "${YELLOW}Tips:${NC}"
        echo -e "${YELLOW}1. Run './docker-test.sh --debug' to enter an interactive shell for debugging.${NC}"
        
        if [ "$MOCK_NFTABLES" != "1" ]; then
            echo -e "${YELLOW}2. Try with the --MOCK_NFTABLES option to use the stub.${NC}"
        else
            echo -e "${YELLOW}2. Make sure the MOCK_NFTABLES variable is properly defined in the tests.${NC}"
        fi
        
        exit 1
    fi
fi
