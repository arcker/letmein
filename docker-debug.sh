#!/bin/sh
# Script de débogage pour Docker avec Alpine Linux (utilise /bin/sh au lieu de /bin/bash)

# Créer un script temporaire pour les tests Docker avec sortie détaillée
TEMP_DIR=$(mktemp -d)
DOCKER_SCRIPT="$TEMP_DIR/run-docker-tests.sh"

cat > "$DOCKER_SCRIPT" << 'EOF'
#!/bin/sh
set -x  # Affiche toutes les commandes exécutées

echo "=== INITIALISATION DE L'ENVIRONNEMENT DE TEST ==="
echo "Contenu du répertoire tests:"
ls -la ./tests

echo "=== PRÉPARATION DES TESTS ==="
cd ./tests
echo "État nftables initial:"
sudo nft list ruleset

echo "=== EXÉCUTION DU TEST KNOCK ==="
echo "Commande: ./run-tests.sh knock"
./run-tests.sh knock
KNOCK_RESULT=$?
echo "Résultat du test knock: $KNOCK_RESULT"

echo "État nftables après knock:"
sudo nft list ruleset | grep -C 5 letmein

echo "=== EXÉCUTION DU TEST CLOSE ==="
echo "Commande: ./run-tests.sh close"
./run-tests.sh close
CLOSE_RESULT=$?
echo "Résultat du test close: $CLOSE_RESULT"

echo "État nftables après close:"
sudo nft list ruleset | grep -C 5 letmein

echo "=== RÉSUMÉ DES TESTS ==="
echo "Knock: $KNOCK_RESULT"
echo "Close: $CLOSE_RESULT"

if [ $KNOCK_RESULT -eq 0 ] && [ $CLOSE_RESULT -eq 0 ]; then
    echo "Tous les tests ont réussi"
    exit 0
else
    echo "Au moins un test a échoué"
    exit 1
fi
EOF

chmod +x "$DOCKER_SCRIPT"

# Exécution du conteneur Docker avec le script de test détaillé
echo "Lancement des tests détaillés dans Docker..."
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
    -v "$(pwd):/app" \
    -v "$DOCKER_SCRIPT:/app/custom-test.sh" \
    --workdir /app \
    letmein-test \
    sh /app/custom-test.sh

# Nettoyage
rm -f "$DOCKER_SCRIPT"
rm -rf "$TEMP_DIR"
