#!/bin/sh
# Script détaillé pour voir l'exécution complète des tests knock et close dans Docker

# Créer un script temporaire pour les tests détaillés
TEMP_DIR=$(mktemp -d)
DOCKER_SCRIPT="$TEMP_DIR/detailed-test.sh"

cat > "$DOCKER_SCRIPT" << 'EOF'
#!/bin/sh
# Script d'exécution détaillée des tests dans le conteneur

# Installation de outils pour un meilleur débogage
apk add --no-cache bash

echo -e "\n===== PRÉPARATION DE L'ENVIRONNEMENT DE TEST ====="
echo -e "\n=== État initial de nftables avant initialisation ==="
nft list ruleset

echo -e "\n=== Exécution du script d'initialisation des tests ==="
cd /app/tests
sh setup-nftables.sh
echo "Code de retour de setup-nftables.sh: $?"

echo -e "\n=== État nftables après initialisation ==="
nft list ruleset

echo -e "\n===== TEST KNOCK - DÉTAILS COMPLETS ====="
echo -e "\n=== Exécution du test knock ==="
cat run-tests.sh | grep "knock)" -A 50 | grep -B 50 ";;$" | head -n 100

echo -e "\n=== Démarrage des services pour le test knock ==="
cd /app
mkdir -p /run/letmeind
mkdir -p /run/letmeinfwd
echo -e "\n=== Exécution de letmeind ==="
./target/debug/letmeind --foreground --conf tests/conf/tcp.conf &
LETMEIND_PID=$!
sleep 1
echo "PID de letmeind: $LETMEIND_PID"

echo -e "\n=== Exécution de letmeinfwd ==="
./target/debug/letmeinfwd --foreground --conf tests/conf/tcp.conf &
LETMEINFWD_PID=$!
sleep 1
echo "PID de letmeinfwd: $LETMEINFWD_PID"

echo -e "\n=== État nftables avant le test knock ==="
nft list ruleset

echo -e "\n=== Exécution du test knock ==="
cd tests
./run-tests.sh knock
KNOCK_RESULT=$?
echo "Code de retour du test knock: $KNOCK_RESULT"

echo -e "\n=== État nftables après le test knock ==="
nft list ruleset

echo -e "\n===== TEST CLOSE - DÉTAILS COMPLETS ====="
echo -e "\n=== Exécution du test close ==="
cat run-tests.sh | grep "close)" -A 50 | grep -B 50 ";;$" | head -n 100

echo -e "\n=== Exécution du test close ==="
./run-tests.sh close
CLOSE_RESULT=$?
echo "Code de retour du test close: $CLOSE_RESULT"

echo -e "\n=== État nftables après le test close ==="
nft list ruleset

echo -e "\n=== Nettoyage des processus ==="
kill $LETMEIND_PID $LETMEINFWD_PID
sleep 1

echo -e "\n===== RÉSUMÉ DES TESTS ====="
echo "Test knock: $KNOCK_RESULT (0=succès, autre=échec)"
echo "Test close: $CLOSE_RESULT (0=succès, autre=échec)"

if [ $KNOCK_RESULT -eq 0 ] && [ $CLOSE_RESULT -eq 0 ]; then
    echo "Tous les tests ont réussi"
    exit 0
else
    echo "Au moins un test a échoué"
    exit 1
fi
EOF

chmod +x "$DOCKER_SCRIPT"

# Construction de la commande Docker
echo "===== LANCEMENT DES TESTS DÉTAILLÉS DANS DOCKER ====="
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
    -v "$DOCKER_SCRIPT:/detailed-test.sh" \
    --workdir /app \
    letmein-test \
    sh /detailed-test.sh

# Nettoyage des fichiers temporaires
rm -f "$DOCKER_SCRIPT"
rm -rf "$TEMP_DIR"
