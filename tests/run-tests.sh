#!/bin/sh
# -*- coding: utf-8 -*-

basedir="$(realpath "$0" | xargs dirname)"
basedir="$basedir/.."

info()
{
    echo "--- $*"
}

# strace configuration
# If DISABLE_STRACE is defined, don't use strace to avoid conflicts with seccomp
if [ "$DISABLE_STRACE" = "1" ]; then
    info "Disabling strace to avoid conflicts with seccomp"
    STRACE_CMD=""
    export STRACE_DISABLED=1
else
    # Normal strace configuration
    STRACE_CMD="strace -f"
    export STRACE_DISABLED=0
fi

# seccomp configuration
# If LETMEIN_DISABLE_SECCOMP is defined, disable seccomp for all components
if [ "$LETMEIN_DISABLE_SECCOMP" = "1" ]; then
    info "Disabling seccomp for all components (letmeind, letmeinfwd, letmein)"
    SECCOMP_OPT="--seccomp off"
else
    SECCOMP_OPT=""
fi

error()
{
    echo "=== ERROR: $*" >&2
}

warning()
{
    echo "=== WARNING: $*" >&2
}

die()
{
    error "$*"
    exit 1
}

build_project()
{
    info "Building project..."
    cd "$basedir" || die "cd failed"
    ./build.sh || die "Build failed"
}

cargo_clippy()
{
    cargo clippy -- --deny warnings || die "cargo clippy failed"
    cargo clippy --tests -- --deny warnings || die "cargo clippy --tests failed"
}

# Check if nftables is available and operational on the system
check_nftables()
{
    info "Checking nftables availability..."
    
    # Check if we're in a WSL environment (where nftables may not work correctly)
    if grep -qi 'microsoft\|WSL' /proc/version; then
        warning "WSL environment detected. Rule verification tests will be disabled in WSL."
        return 1
    fi
    
    # Check if the system nft command is accessible
    # Ignore the project version that might be in the PATH
    if [ ! -x "/sbin/nft" ] && [ ! -x "/usr/sbin/nft" ]; then
        warning "The system command 'nft' (nftables) is not installed or accessible. Rule verification tests will be disabled."
        return 1
    fi
    
    # Check if we can execute the system nft command with sudo
    echo "=== nft command details ===="
    which nft
    ls -l $(which nft 2>/dev/null || echo "nft not found")
    
    echo "=== System details ===="
    uname -a
    cat /proc/version
    
    echo "=== Trying to execute nft list ruleset ===="
    if command -v sudo > /dev/null; then
        echo "Attempting with sudo /sbin/nft list ruleset:"
        sudo /sbin/nft list ruleset 2>&1 || echo "Command failed with code: $?"
        
        if [ -x "/usr/sbin/nft" ]; then
            echo "Attempting with sudo /usr/sbin/nft list ruleset:"
            sudo /usr/sbin/nft list ruleset 2>&1 || echo "Command failed with code: $?"
        fi
    else
        echo "sudo is not installed"
        echo "Attempting without sudo:"
        /sbin/nft list ruleset 2>&1 || echo "Command failed with code: $?"
    fi
    
    if ! sudo /sbin/nft list ruleset &> /dev/null && ! sudo /usr/sbin/nft list ruleset &> /dev/null; then
        warning "Unable to execute 'sudo nft list ruleset' with the system command. Check sudo permissions."
        return 1
    fi
    
    info "System nftables is available and operational!"
    return 0
}

# Check for the presence of an nftables rule for a specific address and port
verify_nft_rule_exists()
{
    local addr="$1"
    local port="$2"
    local proto="$3"
    
    info "--- Checking for the presence of nftables rule for $addr port $port/$proto..."

    # Toujours vérifier les règles nftables

    # 1. D'abord essayer avec letmeinfwd verify
    local verify_result=0
    if "$target/letmeinfwd" --help | grep -q -- "--should-exist"; then
        # La nouvelle version avec --should-exist est supportée
        info "Using letmeinfwd verify with --should-exist=true to check rule..."
        if "$target/letmeinfwd" --config "$conf" verify --address "$addr" --port "$port" --protocol "$proto" --should-exist=true; then
            info "SUCCESS: Rule found for $addr port $port/$proto using letmeinfwd verify"
            return 0
        else
            verify_result=1
            warning "First verification failed with letmeinfwd verify, trying direct nft check as fallback..."
        fi
    else
        warning "--should-exist not supported, using direct nft check instead..."
        verify_result=1
    fi

    # 2. Si letmeinfwd verify a échoué ou n'est pas disponible, vérifier directement avec nft
    if [ $verify_result -ne 0 ]; then
        info "Performing direct nft check to find rule for $addr port $port/$proto..."
        # Convertir IPv6 pour la recherche grep (::1 -> \:\:1)
        local grep_addr="$(echo "$addr" | sed 's/:/\\:/g')"
        
        # Vérifier d'abord si la règle existe dans la sortie nft
        local nft_output=$(nft list ruleset)
        
        # Rechercher une correspondance de l'adresse ET du port dans la sortie nft
        # Ceci dépend un peu du format de sortie de nft, mais c'est une bonne approximation
        if echo "$nft_output" | grep -qE "(saddr|addr) ${grep_addr}" && echo "$nft_output" | grep -qE "dport ${port}"; then
            info "SUCCESS: Rule found for $addr port $port/$proto using direct nft check!"
            return 0
        elif echo "$nft_output" | grep -q "${grep_addr}.*dport ${port}" || echo "$nft_output" | grep -q "dport ${port}.*${grep_addr}"; then
            info "SUCCESS: Rule found for $addr port $port/$proto using pattern matching!"
            return 0
        else
            # Vérification plus spécifique pour IPv4/IPv6
            if [ "$addr" = "127.0.0.1" ] && echo "$nft_output" | grep -q "ip saddr 127.0.0.1" && echo "$nft_output" | grep -q "dport $port"; then
                info "SUCCESS: IPv4 rule found for $addr port $port/$proto by specific pattern!"
                return 0
            elif [ "$addr" = "::1" ] && echo "$nft_output" | grep -q "ip6 saddr ::1" && echo "$nft_output" | grep -q "dport $port"; then
                info "SUCCESS: IPv6 rule found for $addr port $port/$proto by specific pattern!"
                return 0
            else
                # Si le format est ::ffff:127.0.0.1, vérifier aussi pour 127.0.0.1
                if [[ "$addr" == "::ffff:"* ]]; then
                    local ipv4_addr="${addr#::ffff:}"
                    if echo "$nft_output" | grep -q "ip saddr $ipv4_addr" && echo "$nft_output" | grep -q "dport $port"; then
                        info "SUCCESS: IPv4-mapped rule found for $addr port $port/$proto through IPv4 pattern!"
                        return 0
                    fi
                fi
            fi
            
            # Si on arrive ici, la règle n'a pas été trouvée
            die "ERROR: nftables rule not found for $addr port $port/$proto after all verification methods!"
            return 1
        fi
    fi
}

# Check for the absence of an nftables rule for a specific address and port
verify_nft_rule_missing()
{
    local addr="$1"
    local port="$2"
    local proto="$3"
    
    info "--- Checking for the ABSENCE of nftables rule for $addr port $port/$proto..."

    # Toujours vérifier les règles nftables

    # 1. D'abord essayer avec letmeinfwd verify
    local verify_result=0
    if "$target/letmeinfwd" --help | grep -q -- "--should-exist"; then
        # La nouvelle version avec --should-exist est supportée
        info "Using letmeinfwd verify with --should-exist=true to check rule absence..."
        # Pour vérifier l'absence de règle, on s'attend à ce que la commande avec --should-exist=true échoue
        if "$target/letmeinfwd" --config "$conf" verify --address "$addr" --port "$port" --protocol "$proto" --should-exist=true; then
            verify_result=1
            warning "First verification indicates rule is still present, trying direct nft check as fallback..."
        else
            # La règle est absente, c'est un succès pour le test d'absence
            info "SUCCESS: Rule confirmed to be absent for $addr port $port/$proto using letmeinfwd verify"
            return 0
        fi
    else
        warning "--should-exist not supported, using direct nft check instead for rule absence..."
        verify_result=1
    fi

    # 2. Si letmeinfwd verify a échoué ou n'est pas disponible, vérifier directement avec nft
    if [ $verify_result -ne 0 ]; then
        info "Performing direct nft check to confirm absence of rule for $addr port $port/$proto..."
        # Convertir IPv6 pour la recherche grep (::1 -> \:\:1)
        local grep_addr="$(echo "$addr" | sed 's/:/\\:/g')"
        
        # Vérifier si la règle existe dans la sortie nft
        local nft_output=$(nft list ruleset)
        
        # Vérifications spécifiques pour s'assurer que la règle n'existe pas
        local rule_found=0
        
        # D'abord vérifier selon le format attendu de l'adresse IP (IPv4 ou IPv6)
        if [ "$addr" = "127.0.0.1" ] && echo "$nft_output" | grep -q "ip saddr 127.0.0.1" && echo "$nft_output" | grep -q "dport $port"; then
            rule_found=1
        elif [ "$addr" = "::1" ] && echo "$nft_output" | grep -q "ip6 saddr ::1" && echo "$nft_output" | grep -q "dport $port"; then
            rule_found=1
        # Vérifier si c'est un format IPv4-mapped (::ffff:127.0.0.1)
        elif [[ "$addr" == "::ffff:"* ]]; then
            local ipv4_addr="${addr#::ffff:}"
            if echo "$nft_output" | grep -q "ip saddr $ipv4_addr" && echo "$nft_output" | grep -q "dport $port"; then
                rule_found=1
            fi
        # Vérification plus générique par motifs
        elif echo "$nft_output" | grep -q "${grep_addr}.*dport ${port}" || echo "$nft_output" | grep -q "dport ${port}.*${grep_addr}"; then
            rule_found=1
        fi
        
        if [ $rule_found -eq 0 ]; then
            info "SUCCESS: Rule confirmed to be absent for $addr port $port/$proto using direct nft check!"
            return 0
        else
            die "ERROR: nftables rule is still present for $addr port $port/$proto after checking with nft!"
            return 1
        fi
    fi
}

run_tests_genkey()
{
    info "### Running test: gen-key ###"

    local conf="$testdir/conf/udp.conf"

    local res="$("$target/letmein" --config "$conf"  gen-key  --user 12345678)"

    local user="$(echo "$res" | cut -d'=' -f1 | cut -d' ' -f1)"
    local key="$(echo "$res" | cut -d'=' -f2 | cut -d' ' -f2)"

    [ "$user" = "12345678" ] || die "Got invalid user"
}

# Exécute le test complet (knock > verify > close) pour une adresse IP spécifique
run_test_cycle()
{
    local test_type="$1"   # tcp ou udp
    local ip_version="$2" # ipv4, ipv6, ou dual (les deux)

    info "### Running complete test cycle: $test_type with $ip_version ###"

    rm -rf "$rundir"
    local conf="$testdir/conf/$test_type.conf"

    # Démarrer les services
    info "Starting letmeinfwd..."
    "$target/letmeinfwd" \
        --test-mode \
        --no-systemd \
        --rundir "$rundir" \
        --seccomp off \
        --config "$conf" &
    pid_letmeinfwd=$!

    info "Starting letmeind..."
    "$target/letmeind" \
        --no-systemd \
        --rundir "$rundir" \
        --seccomp off \
        --config "$conf" &
    pid_letmeind=$!

    wait_for_pidfile letmeinfwd "$pid_letmeinfwd"
    wait_for_pidfile letmeind "$pid_letmeind"
    
    # 1. KNOCK: Exécuter la requête knock selon la version IP demandée
    info "Knocking with $ip_version..."
    local ip_flags=""
    local addr=""
    
    case "$ip_version" in
        ipv4)
            ip_flags="--ipv4"
            addr="127.0.0.1"
            ;;
        ipv6)
            ip_flags="--ipv6"
            addr="::1"
            ;;
        dual|*)
            ip_flags=""
            addr="::1" # Par défaut on vérifie d'abord IPv6
            ;;
    esac
    
    "$target/letmein" \
        --verbose \
        $SECCOMP_OPT \
        --config "$conf" \
        knock \
        --user 12345678 \
        $ip_flags \
        localhost 42 \
        || die "letmein knock failed with $ip_version"
    
    # 2. VERIFY: Vérifier immédiatement les règles nftables après le knock
    info "Verifying nftables rules after $ip_version knock..."
    if $nftables_available; then
        echo "--- Toutes les règles nftables après knock $ip_version ($test_type) ---"
        echo "=== Liste des règles nftables actuelles ==="
        nft list ruleset
        if [ $? -ne 0 ]; then
            echo "ERREUR: Échec lors de la liste des règles nftables"
        fi
        echo "--- Filtrage pour letmein ---"
        echo "=== Recherche des règles letmein ==="
        RULES_OUTPUT=$(nft list ruleset | grep -i letmein)
        if [ -z "$RULES_OUTPUT" ]; then
            echo "INFORMATION: Aucune règle letmein n'a été trouvée"
        else
            echo "$RULES_OUTPUT"
        fi
        echo "--- Inspection détaillée de letmein-dynamic ---"
        echo "=== Vérification de la chaîne letmein-dynamic ==="
        nft list chain inet filter letmein-dynamic
        if [ $? -ne 0 ]; then
            echo "ERREUR: Impossible d'afficher la chaîne letmein-dynamic"
        fi
        
        # Vérifier si la règle existe avec notre fonction de vérification
        info "Vérification formelle de la règle avec letmeinfwd verify"
        if [ "$test_type" = "tcp" ]; then
            if ! verify_nft_rule_exists "$conf" "$addr" 42 "tcp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (TCP) n'a pas été trouvée après knock"
                echo "Détail: Aucune règle trouvée pour $addr port 42/tcp"
            else
                info "Règle TCP $test_type $ip_version vérifiée avec succès après knock"
            fi
        else
            if ! verify_nft_rule_exists "$conf" "$addr" 42 "udp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (UDP) n'a pas été trouvée après knock"
                echo "Détail: Aucune règle trouvée pour $addr port 42/udp"
            else
                info "Règle UDP $test_type $ip_version vérifiée avec succès après knock"
            fi
        fi
    fi
    
    # 3. CLOSE: Fermer la connexion
    info "Closing connection after $ip_version knock..."
    # Attendre un peu pour s'assurer que la règle a eu le temps d'être enregistrée
    sleep 1
    
    # Appeler close
    "$target/letmein" \
        --verbose \
        $SECCOMP_OPT \
        --config "$conf" \
        close \
        $ip_flags \
        localhost 42 \
        || warning "letmein close failed with $ip_version"
    
    # 4. VERIFY CLOSE: Vérifier que la règle a bien été supprimée
    if $nftables_available; then
        info "Verifying nftables rules after $ip_version close..."
        echo "--- Toutes les règles nftables après close $ip_version ---"
        echo "=== Liste des règles nftables actuelles ==="
        nft list ruleset
        if [ $? -ne 0 ]; then
            echo "ERREUR: Échec lors de la liste des règles nftables"
        fi
        echo "--- Filtrage pour letmein après close ---"
        nft list ruleset | grep -i letmein || echo "Aucune règle letmein n'a été trouvée (attendu après close)"
        echo "--- Inspection détaillée de letmein-dynamic après close ---"
        echo "=== Vérification de la chaîne letmein-dynamic ==="
        nft list chain inet filter letmein-dynamic
        if [ $? -ne 0 ]; then
            echo "ERREUR: Impossible d'afficher la chaîne letmein-dynamic"
        fi
        
        # Vérifier formellement l'absence de règle avec notre fonction de vérification
        info "Vérification formelle de l'absence de règle après close"
        if [ "$test_type" = "tcp" ]; then
            if ! verify_nft_rule_missing "$conf" "$addr" 42 "tcp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (TCP) est toujours présente après close"
                echo "Détail: Règle toujours présente pour $addr port 42/tcp"
            else
                info "Absence de règle TCP $test_type $ip_version vérifiée avec succès après close"
            fi
        else
            if ! verify_nft_rule_missing "$conf" "$addr" 42 "udp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (UDP) est toujours présente après close"
                echo "Détail: Règle toujours présente pour $addr port 42/udp"
            else
                info "Absence de règle UDP $test_type $ip_version vérifiée avec succès après close"
            fi
        fi
    fi
    
    kill_all_and_wait
}

# Fonction pour exécuter les tests knock (remplacement de run_tests_knock)
run_tests_knock()
{
    local test_type="$1"
    
    info "### Running tests: knock $test_type ###"
    
    # Exécuter le cycle complet pour chaque version IP
    run_test_cycle "$test_type" "ipv4"
    run_test_cycle "$test_type" "ipv6"
    run_test_cycle "$test_type" "dual"
    
    info "All knock tests completed for $test_type"
}

# Fonction pour exécuter des tests de fermeture
run_tests_close()
{
    local test_type="$1"

    info "### Running close tests: $test_type ###"
    info "Note: Les tests 'knock' incluent déjà le cycle complet (knock > verify > close)."

    # Cette fonction exécute des tests de fermeture spécifiques pour chaque type d'IP
    # en utilisant notre nouvelle fonction de test complet pour chaque protocole
    run_close_test_cycle "$test_type" "ipv4"
    run_close_test_cycle "$test_type" "ipv6"
    run_close_test_cycle "$test_type" "dual"
    
    info "All close tests completed for $test_type"
}

# Exécute un test complet de fermeture après ouverture (knock puis close) pour une adresse IP
run_close_test_cycle()
{
    local test_type="$1"  # tcp ou udp
    local ip_version="$2" # ipv4, ipv6, ou dual (les deux)

    info "### Running specific close test cycle: $test_type with $ip_version ###"

    rm -rf "$rundir"
    local conf="$testdir/conf/$test_type.conf"

    # Définir les flags selon la version IP
    local ip_flags=""
    local addr=""
    
    case "$ip_version" in
        ipv4)
            ip_flags="--ipv4"
            addr="127.0.0.1"
            ;;
        ipv6)
            ip_flags="--ipv6"
            addr="::1"
            ;;
        dual|*)
            ip_flags=""
            addr="::1" # Par défaut on vérifie IPv6 pour les tests dual
            ;;
    esac

    # Démarrer les services
    info "Starting letmeinfwd..."
    "$target/letmeinfwd" \
        --test-mode \
        --no-systemd \
        --rundir "$rundir" \
        --seccomp off \
        --config "$conf" &
    pid_letmeinfwd=$!

    info "Starting letmeind..."
    "$target/letmeind" \
        --no-systemd \
        --rundir "$rundir" \
        --seccomp off \
        --config "$conf" &
    pid_letmeind=$!

    wait_for_pidfile letmeinfwd "$pid_letmeinfwd"
    wait_for_pidfile letmeind "$pid_letmeind"

    # 1. KNOCK: Ouvrir le port avec knock
    info "Opening port with knock $ip_version..."
    "$target/letmein" \
        --verbose \
        $SECCOMP_OPT \
        --config "$conf" \
        knock \
        --user 12345678 \
        $ip_flags \
        localhost 42 \
        || die "letmein knock failed with $ip_version"
    
    # 2. VERIFY: Vérifier que la règle a bien été ajoutée
    if $nftables_available && [ "$test_type" != "test" ]; then
        sleep 1  # Attendre que les règles soient bien appliquées
        echo "--- Règles nftables après knock $ip_version ---"
        echo "=== Liste des règles nftables actuelles ==="
        nft list ruleset
        if [ $? -ne 0 ]; then
            echo "ERREUR: Échec lors de la liste des règles nftables"
        fi
        echo "--- Inspection détaillée de letmein-dynamic ---"
        echo "=== Vérification de la chaîne letmein-dynamic ==="
        nft list chain inet filter letmein-dynamic
        if [ $? -ne 0 ]; then
            echo "ERREUR: Impossible d'afficher la chaîne letmein-dynamic"
        fi
        
        # Vérifier les règles avec notre fonction de vérification
        if [ "$test_type" = "tcp" ]; then
            if ! verify_nft_rule_exists "$conf" "$addr" 42 "tcp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (TCP) n'a pas été trouvée après knock"
                echo "Détail: Aucune règle trouvée pour $addr port 42/tcp"
            else
                info "Règle TCP $test_type $ip_version vérifiée avec succès après knock"
            fi
        else
            if ! verify_nft_rule_exists "$conf" "$addr" 42 "udp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (UDP) n'a pas été trouvée après knock"
                echo "Détail: Aucune règle trouvée pour $addr port 42/udp"
            else
                info "Règle UDP $test_type $ip_version vérifiée avec succès après knock"
            fi
        fi
    fi

    # 3. CLOSE: Fermer le port
    info "Closing port with close $ip_version..."
    "$target/letmein" \
        --verbose \
        $SECCOMP_OPT \
        --config "$conf" \
        close \
        --user 12345678 \
        $ip_flags \
        localhost 42 \
        || die "letmein close failed with $ip_version"
    
    # 4. VERIFY CLOSE: Vérifier que la règle a bien été supprimée
    if $nftables_available && [ "$test_type" != "test" ]; then
        sleep 1  # Attendre que les règles soient bien supprimées
        echo "--- Règles nftables après close $ip_version ---"
        echo "=== Liste des règles nftables actuelles ==="
        nft list ruleset
        if [ $? -ne 0 ]; then
            echo "ERREUR: Échec lors de la liste des règles nftables"
        fi
        
        # Vérifier l'absence de règle
        if [ "$test_type" = "tcp" ]; then
            if ! verify_nft_rule_missing "$conf" "$addr" 42 "tcp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (TCP) est toujours présente après close"
                echo "Détail: Règle toujours présente pour $addr port 42/tcp"
            else
                info "Absence de règle TCP $test_type $ip_version vérifiée avec succès après close"
            fi
        else
            if ! verify_nft_rule_missing "$conf" "$addr" 42 "udp"; then
                warning "ERREUR DE VÉRIFICATION: La règle $test_type $ip_version (UDP) est toujours présente après close"
                echo "Détail: Règle toujours présente pour $addr port 42/udp"
            else
                info "Absence de règle UDP $test_type $ip_version vérifiée avec succès après close"
            fi
        fi
    fi

    kill_all_and_wait
}

wait_for_pidfile()
{
    local name="$1"
    local pid="$2"

    for i in $(seq 0 29); do
        if [ -r "$rundir/$name/$name.pid" ]; then
            if [ "$pid" != "$(cat "$rundir/$name/$name.pid")" ]; then
                die "$name: Invalid PID-file."
            fi
            return
        fi
        sleep 0.1
    done
    die "$name PID-file is missing. Did $name fail to start?"
}

kill_all()
{
    kill_letmeind
    kill_letmeinfwd
}

kill_all_and_wait()
{
    kill_all
    wait
}

kill_letmeinfwd()
{
    if [ -n "$pid_letmeinfwd" ]; then
        kill -TERM "$pid_letmeinfwd" >/dev/null 2>&1
        pid_letmeinfwd=
    fi
}

kill_letmeind()
{
    if [ -n "$pid_letmeind" ]; then
        kill -TERM "$pid_letmeind" >/dev/null 2>&1
        pid_letmeind=
    fi
}

cleanup()
{
    kill_all
    if [ -n "$tmpdir" ]; then
        rm -rf "$tmpdir"
        tmpdir=
    fi
}

cleanup_and_exit()
{
    cleanup
    exit 1
}
 
pid_letmeinfwd=
pid_letmeind=

# Fonction pour initialiser nftables avec notre script d'initialisation
initialize_nftables()
{
    # Ne pas exécuter en mode stub
    if [ "$MOCK_NFTABLES" = "1" ]; then
        info "Mode stub nftables activé, pas besoin d'initialiser nftables"
        return 0
    fi
    
    info "Initialisation de nftables pour les tests..."
    if [ -x "$testdir/setup-nftables.sh" ]; then
        "$testdir/setup-nftables.sh"
        if [ $? -ne 0 ]; then
            warning "ERREUR: Échec lors de l'initialisation de nftables"
            echo "La commande setup-nftables.sh a retourné le code d'erreur $?"
        else
            info "Initialisation de nftables réussie"
        fi
    else
        warning "Le script setup-nftables.sh n'existe pas ou n'est pas exécutable"
    fi
}

# Fonction pour initialiser le fichier de configuration avec les clés utilisateur
initialize_config()
{
    local config_dir="/opt/letmein/etc"
    local config_file="$config_dir/letmein.conf"
    local test_user="12345678"
    
    info "Initialisation du fichier de configuration pour les tests..."
    
    # Créer le répertoire si nécessaire
    echo "Création du répertoire de configuration: $config_dir"
    mkdir -p "$config_dir"
    if [ $? -ne 0 ]; then
        warning "ERREUR: Impossible de créer le répertoire de configuration $config_dir"
        echo "Détail: La commande mkdir a échoué avec le code d'erreur $?"
    else
        info "Répertoire de configuration créé avec succès"
    fi
    
    # Générer une clé pour l'utilisateur de test si nécessaire
    if ! grep -q "$test_user" "$config_file" 2>/dev/null; then
        # Générer une clé aléatoire pour l'utilisateur
        local key="$(openssl rand -hex 16)"
        echo "Ajout de la clé pour l'utilisateur $test_user au fichier $config_file"
        echo "$test_user:$key" >> "$config_file"
        if [ $? -ne 0 ]; then
            warning "ERREUR: Impossible d'ajouter la clé au fichier $config_file"
            echo "Détail: La commande echo a échoué avec le code d'erreur $?"
        else
            info "Clé ajoutée avec succès au fichier de configuration"
        fi
        info "Clé ajoutée pour l'utilisateur $test_user dans $config_file"
    else
        info "La clé pour l'utilisateur $test_user existe déjà dans $config_file"
    fi
    
    # Vérifier que le fichier est utilisable
    if [ ! -r "$config_file" ]; then
        warning "Le fichier de configuration $config_file n'est pas lisible"
    else
        info "Fichier de configuration $config_file initialisé avec succès"
    fi
}

# Variable globale pour déterminer si les vérifications nftables doivent être effectuées
nftables_available=false

[ -n "$TMPDIR" ] || export TMPDIR=/tmp
tmpdir="$(mktemp --tmpdir="$TMPDIR" -d letmein-test.XXXXXXXXXX)"
[ -d "$tmpdir" ] || die "Failed to create temporary directory"
rundir="$tmpdir/run"

target="$basedir/target/debug"
testdir="$basedir/tests"
stubdir="$testdir/stubs"

export PATH="$target:$PATH"

trap cleanup_and_exit INT TERM
trap cleanup EXIT

info "Temporary directory is: $tmpdir"

# Utilisation systématique des vraies nftables
info "Mode réel nftables activé"

# Vérifier si nftables est disponible et opérationnel
if check_nftables; then
    nftables_available=true
    info "Les vérifications de règles nftables seront effectuées"
else
    nftables_available=false
    warning "Les vérifications de règles nftables seront désactivées (nftables non disponible)"
    
    # Initialiser nftables avec notre script (tentative de correction)
    initialize_nftables
fi

# Initialiser le fichier de configuration
initialize_config

build_project
cargo_clippy

# Déterminer quels tests exécuter en fonction des arguments
if [ $# -gt 0 ]; then
    info "Exécution des tests spécifiés: $*"
    for test in "$@"; do
        case "$test" in
            "gen-key")
                run_tests_genkey
                ;;
            "knock")
                run_tests_knock tcp
                run_tests_knock udp
                ;;
            "close")
                run_tests_close tcp
                run_tests_close udp
                ;;
            *)
                warning "Test inconnu: $test"
                ;;
        esac
    done
else
    # Si aucun test n'est spécifié, exécuter tous les tests
    info "Exécution de tous les tests"
    run_tests_genkey
    run_tests_knock tcp
    run_tests_knock udp
    run_tests_close tcp
    run_tests_close udp
fi

info "All tests Ok."

# vim: ts=4 sw=4 expandtab
