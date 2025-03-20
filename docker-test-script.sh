#!/bin/bash
# Script d'exécution de test Docker avec affichage détaillé complet

# Activer le mode trace
set -x

# Arguments passés au script
TEST_ARGS="$@"

echo "=== DÉBUT DES TESTS DOCKER AVEC TRACE COMPLÈTE ==="
echo "Tests à exécuter: $TEST_ARGS"

# Configuration pour un affichage détaillé
export PS4='+ [$(date +%H:%M:%S)] ${BASH_SOURCE}:${LINENO}: '
export LOG_LEVEL=debug
export RUST_LOG=debug
export RUST_BACKTRACE=full
export LETMEIN_DISABLE_SECCOMP=1

# Compilation du projet
cargo build

# Accéder au répertoire de tests
cd ./tests

# Affichage de l'état nftables avant les tests
echo "=== ÉTAT NFTABLES AVANT LES TESTS ==="
nft list ruleset

# Exécution des tests avec mode trace
bash -x ./run-tests.sh $TEST_ARGS

# Capturer le code de retour
TEST_RESULT=$?

# Affichage de l'état nftables après les tests
echo "=== ÉTAT NFTABLES APRÈS LES TESTS ==="
nft list ruleset

echo "=== FIN DES TESTS DOCKER ==="
echo "Résultat: $TEST_RESULT"

# Retourner le code de sortie des tests
exit $TEST_RESULT
