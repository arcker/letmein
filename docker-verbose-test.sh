#!/bin/bash

# Script temporaire pour avoir une sortie détaillée des tests Docker
# Basé sur test.sh mais avec plus de logs

# Couleurs pour la lisibilité
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Créer un répertoire temporaire pour les tests Docker
TEMP_DIR=$(mktemp -d)
DOCKER_SCRIPT="$TEMP_DIR/run-docker-tests.sh"

# Créer un script détaillé pour l'exécution dans le conteneur
cat > "$DOCKER_SCRIPT" << 'EOF'
#!/bin/sh
set -x  # Active l'affichage de toutes les commandes exécutées

echo "=== DÉBUT DES TESTS DOCKER DÉTAILLÉS ==="
echo "=== TEST_ARGS: $TEST_ARGS ==="

# Affichage de l'environnement
echo "=== VARIABLES D'ENVIRONNEMENT ==="
env | sort

# Affichage de l'état initial des règles nftables
echo "=== ÉTAT INITIAL NFTABLES ==="
nft list ruleset

# Compilation complète avec logs détaillés
echo "=== COMPILATION DÉTAILLÉE ==="
cargo build -v

# Tests unitaires
echo "=== EXÉCUTION DES TESTS UNITAIRES ==="
cargo test -v

# Lancement des tests avec run-tests.sh
echo "=== EXÉCUTION DÉTAILLÉE DES TESTS FONCTIONNELS ==="
cd ./tests

# Analyse des tests demandés
echo "Tests demandés: $TEST_ARGS"

# Exécution des tests pour knock
if echo "$TEST_ARGS" | grep -q "knock"; then
    echo "=== EXÉCUTION DÉTAILLÉE DU TEST KNOCK ==="
    ./run-tests.sh knock
    KNOCK_RESULT=$?
    echo "Résultat du test knock: $KNOCK_RESULT"
    
    # Afficher l'état des règles nftables après knock
    echo "=== ÉTAT NFTABLES APRÈS KNOCK ==="
    nft list ruleset
else
    echo "Test knock non demandé"
fi

# Exécution des tests pour close
if echo "$TEST_ARGS" | grep -q "close"; then
    echo "=== EXÉCUTION DÉTAILLÉE DU TEST CLOSE ==="
    ./run-tests.sh close
    CLOSE_RESULT=$?
    echo "Résultat du test close: $CLOSE_RESULT"
    
    # Afficher l'état des règles nftables après close
    echo "=== ÉTAT NFTABLES APRÈS CLOSE ==="
    nft list ruleset
else
    echo "Test close non demandé"
fi

# Exécution des tests pour gen-key
if echo "$TEST_ARGS" | grep -q "gen-key"; then
    echo "=== EXÉCUTION DÉTAILLÉE DU TEST GEN-KEY ==="
    ./run-tests.sh gen-key
    GENKEY_RESULT=$?
    echo "Résultat du test gen-key: $GENKEY_RESULT"
else
    echo "Test gen-key non demandé"
fi

# Calculer le résultat global
TEST_RESULT=0
if [ "${KNOCK_RESULT:-0}" -ne 0 ] || [ "${CLOSE_RESULT:-0}" -ne 0 ] || [ "${GENKEY_RESULT:-0}" -ne 0 ]; then
    TEST_RESULT=1
fi

echo "=== RÉSUMÉ DES TESTS ==="
echo "Knock: ${KNOCK_RESULT:-non exécuté}"
echo "Close: ${CLOSE_RESULT:-non exécuté}"
echo "Gen-key: ${GENKEY_RESULT:-non exécuté}"
echo "Résultat global: $TEST_RESULT"

echo "=== FIN DES TESTS DOCKER DÉTAILLÉS ==="

# Retourne le statut des tests
exit $TEST_RESULT
EOF

# Rendre le script exécutable
chmod +x "$DOCKER_SCRIPT"

# Construction de la commande Docker
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
    -e "LOG_LEVEL=debug" \
    -e RUST_BACKTRACE=1 \
    -e "TEST_ARGS=knock close" \
    -v "$(pwd):/app" \
    -v "$DOCKER_SCRIPT:/run-docker-tests.sh" \
    --workdir /app \
    letmein-test \
    /run-docker-tests.sh

# Nettoyage du script temporaire
rm -f "$DOCKER_SCRIPT"
rm -rf "$TEMP_DIR"
