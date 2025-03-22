#!/bin/bash

# Script de débogage pour nftables

set -e

echo "=== DÉBOGAGE NFTABLES ==="
echo "Utilisateur: $(whoami)"

# Lister les tables nftables
echo "=== TABLES ET RÈGLES ACTUELLES ==="
if command -v nft >/dev/null 2>&1; then
    nft list ruleset
else 
    echo "nft non trouvé, essayant avec sudo"
    if sudo -E nft list ruleset; then
        echo "Succès avec sudo nft"
    else
        echo "Échec avec sudo nft"
        exit 1
    fi
fi

# Vérifier la présence des chaînes letmein
echo "=== VÉRIFICATION DES CHAÎNES LETMEIN ==="
if ! nft list ruleset | grep -q LETMEIN; then
    echo "Aucune chaîne LETMEIN trouvée"
else
    echo "Chaînes LETMEIN trouvées:"
    nft list ruleset | grep -A 5 LETMEIN || true
fi

# Plus d'informations sur l'environnement
echo "=== ENVIRONNEMENT ==="
if [ -f /.dockerenv ]; then
    echo "Exécution dans un conteneur Docker"
fi

# Vérifier les droits CAP_NET_ADMIN
echo "=== CAPACITÉS ==="
if command -v capsh >/dev/null 2>&1; then
    capsh --print | grep -i cap_net_admin || echo "CAP_NET_ADMIN non trouvé"
else
    echo "capsh non disponible pour vérifier les capacités"
fi

echo "=== FIN DU DÉBOGAGE NFTABLES ==="
