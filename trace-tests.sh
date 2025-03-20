#!/bin/bash
# Script pour exécuter les tests avec une trace complète

# Couleurs pour les sorties
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== EXÉCUTION DES TESTS AVEC TRACE COMPLÈTE ===${NC}"
echo -e "${BLUE}Tests: knock close${NC}"

# Définir les variables d'environnement pour le mode débug
export LOG_LEVEL=debug
export LETMEIN_DISABLE_SECCOMP=1

# Activer le mode trace pour afficher toutes les commandes exécutées
set -x

# Exécuter les tests spécifiés
cd "$(dirname "$0")" || exit 1
cd tests || exit 1

# Exécuter spécifiquement les tests knock et close
./run-tests.sh knock close

# Vérifier si les tests ont réussi
result=$?
set +x

if [ $result -eq 0 ]; then
  echo -e "${GREEN}=== TESTS RÉUSSIS ===${NC}"
else
  echo -e "${RED}=== ÉCHEC DES TESTS (code: $result) ===${NC}"
fi

exit $result
