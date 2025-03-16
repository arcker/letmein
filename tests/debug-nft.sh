#!/bin/sh
# Script de débogage pour afficher l'état des tables nftables

echo "============================================================"
echo "=== DÉBOGAGE NFTABLES - $(date) ==="
echo "============================================================"

echo "\n=== Variables d'environnement ==="
echo "MOCK_NFTABLES=${MOCK_NFTABLES}"
echo "LETMEIN_DISABLE_SECCOMP=${LETMEIN_DISABLE_SECCOMP}"
echo "RUST_BACKTRACE=${RUST_BACKTRACE}"

echo "\n=== Informations système ==="
uname -a
id

echo "\n=== Information nft ==="
which nft
nft --version

echo "\n=== Commande nft list ruleset (format texte) ==="
nft list ruleset 2>&1
RET=$?
echo "Exit code: $RET"

echo "\n=== Commande nft -j list ruleset (format JSON) ==="
nft -j list ruleset 2>&1
RET=$?
echo "Exit code: $RET"

echo "\n=== Tables nftables existantes ==="
nft list tables 2>&1
RET=$?
echo "Exit code: $RET"

echo "\n=== Chaînes nftables existantes ==="
nft list chains 2>&1
RET=$?
echo "Exit code: $RET"

echo "\n=== Analyse spécifique chaîne LETMEIN-INPUT ==="
nft list chain inet filter LETMEIN-INPUT 2>&1
RET=$?
echo "Exit code: $RET"

echo "\n=== Recherche des règles pour le port 42 (tous formats) ==="
nft list ruleset | grep -i "42" || echo "Aucune règle trouvée pour le port 42 (format texte)"
nft -j list ruleset | grep -i "42" || echo "Aucune règle trouvée pour le port 42 (format JSON)"

echo "\n=== Recherche des règles pour les adresses ::1 et 127.0.0.1 ==="
nft list ruleset | grep -E "::1|127.0.0.1" || echo "Aucune règle trouvée pour les adresses ::1 ou 127.0.0.1 (format texte)"
nft -j list ruleset | grep -E "::1|127.0.0.1" || echo "Aucune règle trouvée pour les adresses ::1 ou 127.0.0.1 (format JSON)"

echo "\n=== Contenu du répertoire /run/letmein ==="
ls -la /run/letmein/ 2>/dev/null || echo "Répertoire non disponible"

echo "\n=== Processus letmein en cours d'exécution ==="
ps aux | grep -E "letmeind|letmeinfwd" | grep -v grep || echo "Aucun processus letmein en cours d'exécution"

echo "\n=== Pile d'appel letmeinfwd (vérifications de règles) ==="
ps aux | grep "letmeinfwd" | grep -v grep | awk '{print $2}' | xargs -I{} sh -c 'if [ -n "{}" ]; then echo "PID: {}"; strace -f -p {} -e trace=network 2>&1 | head -n 20 || echo "Échec de strace"; fi' || echo "Processus letmeinfwd non trouvé"

echo "\n=== Test direct de commandes nftables ==="
echo "- Tentative d'ajout d'une règle de test:"
if [ "$MOCK_NFTABLES" = "1" ]; then
    echo "Mode MOCK_NFTABLES activé, affichage des règles simulées"
else
    nft add rule inet filter input tcp dport 12345 accept comment \"test-debug\" 2>&1 || echo "Échec de l'ajout de règle"
    nft list ruleset | grep "12345" || echo "Règle de test non trouvée"
    nft delete rule inet filter input handle $(nft -a list ruleset | grep "12345" | grep -o "handle [0-9]*" | awk '{print $2}') 2>/dev/null || echo "Échec de la suppression"
fi

echo "\n============================================================"
echo "=== FIN DU DÉBOGAGE NFTABLES ==="
echo "============================================================"
