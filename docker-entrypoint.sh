#!/bin/bash
set -euo pipefail

# Logging migliorato
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

debug() {
    if [ "${ENTRYPOINT_DEBUG:-0}" = "1" ]; then
        log "DEBUG: $*" >&2
    fi
}

# Backup delle variabili d'ambiente
ENV_BACKUP_FILE="/tmp/docker-entrypoint.env"
if [ ! -f "$ENV_BACKUP_FILE" ]; then
    export > "$ENV_BACKUP_FILE"
    debug "Environment variables backed up to $ENV_BACKUP_FILE"
fi

############################################################
# Restart come root se necessario
############################################################

if [ "$(id -u)" != "0" ]; then
    debug "Not running as root, restarting with sudo"
    
    # Scrivi gli argomenti dell'entrypoint in un file
    ENTRYPOINT_ARGS_FILE="$HOME/.entrypoint.txt"
    : > "$ENTRYPOINT_ARGS_FILE"  # Crea/svuota il file
    
    for arg in "$@"; do
        printf '%s\n' "$arg" | base64 -w0 >> "$ENTRYPOINT_ARGS_FILE"
        echo >> "$ENTRYPOINT_ARGS_FILE"
    done
    
    debug "Arguments saved to $ENTRYPOINT_ARGS_FILE"
    exec sudo -EH "$0"
fi

# Ripristina gli argomenti se siamo stati riavviati come root
if [ $# -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/.entrypoint.txt" ]; then
    debug "Restoring arguments from /home/${SUDO_USER}/.entrypoint.txt"
    
    # Leggi gli argomenti dal file (in ordine inverso)
    while IFS='' read -r encoded_arg; do
        if [ -n "$encoded_arg" ]; then
            decoded_arg=$(echo "$encoded_arg" | base64 -d)
            set -- "$decoded_arg" "$@"
        fi
    done < "/home/${SUDO_USER}/.entrypoint.txt"
    
    rm "/home/${SUDO_USER}/.entrypoint.txt"
    debug "Arguments restored: $*"
fi

# Determina l'utente amministratore
ADM_USER="${CONTAINER_USERNAME:-ubuntu}"
debug "ADM_USER set to: $ADM_USER"

############################################################
# Esegui script di entrypoint
############################################################

run_entrypoint_scripts() {
    local stage="$1"
    local user="${2:-}"
    local base_path="/etc/entrypoint.d"
    
    if [ -z "$user" ]; then
        local script_path="$base_path/root/$stage"
        log "Running root scripts for stage: $stage"
    else
        local script_path="$base_path/user/$stage"
        log "Running user scripts for stage: $stage (user: $user)"
    fi
    
    if [ ! -d "$script_path" ]; then
        debug "Script directory not found: $script_path"
        return 0
    fi
    
    # Trova ed esegui gli script in ordine
    find "$script_path" -maxdepth 1 -type f -executable -not -name '.*' | sort | while read -r script; do
        if [ -n "$script" ]; then
            log "Executing script: $script"
            if [ -z "$user" ]; then
                "$script" || error "Failed to execute root script: $script"
            else
                gosu "$user" "$script" || error "Failed to execute user script: $script"
            fi
        fi
    done
}

# Lock file per prevenire l'esecuzione multipla degli script init
ENTRYPOINT_LOCK="/var/local/entrypoint.lock"

if [ ! -f "$ENTRYPOINT_LOCK" ]; then
    log "First run detected, executing init scripts"
    run_entrypoint_scripts 'init'
    
    # Esegui script init utente in un ambiente ripristinato
    (
        if [ -f "$ENV_BACKUP_FILE" ]; then
            # Rimuovi le variabili d'ambiente correnti (eccetto PATH)
            while IFS='=' read -r var _; do
                if [ "$var" != "PATH" ] && [ -n "$var" ]; then
                    unset "$var" 2>/dev/null || true
                fi
            done < <(env)
            
            # Carica l'ambiente salvato
            set -a  # Esporta automaticamente le variabili
            source "$ENV_BACKUP_FILE"
            set +a
        fi
        
        run_entrypoint_scripts 'init' "$ADM_USER"
    )
    
    # Crea il file lock
    date +'%s' > "$ENTRYPOINT_LOCK"
    log "Entrypoint lock file created"
else
    debug "Lock file exists, skipping init scripts"
fi

# Esegui sempre gli script di start
run_entrypoint_scripts 'start'
run_entrypoint_scripts 'start' "$ADM_USER"

############################################################
# Configura entrypoint secondario
############################################################

# Se il primo argomento è vuoto o inizia con '-', usa ENTRYPOINT0
if [[ "${1:--}" =~ ^- ]]; then
    if [ -n "${ENTRYPOINT0:-}" ]; then
        log "Using secondary entrypoint: $ENTRYPOINT0"
        
        # Rimuovi '--' se presente
        if [ "$1" = '--' ]; then
            shift
        fi
        
        # Espandi ENTRYPOINT0 senza quote per permettere argomenti multipli
        set -- $ENTRYPOINT0 "$@"
    fi
fi

############################################################
# Configura sistema di init
############################################################

if [ "${S6_ENABLE:-0}" -eq 1 ] || { [ "${S6_ENABLE:-0}" -eq 2 ] && [ $# -eq 0 ]; }; then
    log "Using s6-overlay init system"
    
    # Passa all'utente ADM dopo l'avvio di s6-overlay se ci sono argomenti
    if [ $# -gt 0 ]; then
        set -- gosu "$ADM_USER" "$@"
    fi
    set -- /init "$@"
else
    log "Using tini init system"
    
    # Fallback alla shell utente se non c'è ENTRYPOINT0 e nessun CMD
    if [[ "${1:--}" =~ ^- ]]; then
        ADM_SHELL=$(getent passwd "$ADM_USER" | cut -d: -f7)
        ADM_SHELL="${ADM_SHELL:-/bin/bash}"
        log "Using default shell: $ADM_SHELL"
        set -- "$ADM_SHELL" "$@"
    fi
    
    # Usa tini con gosu per passare all'utente corretto
    set -- tini -s -g -- gosu "$ADM_USER" "$@"
fi

############################################################
# Ripristina ambiente e passa all'utente
############################################################

# Ripristina le variabili d'ambiente
if [ -f "$ENV_BACKUP_FILE" ]; then
    debug "Restoring original environment"
    
    # Rimuovi variabili correnti (eccetto PATH)
    while IFS='=' read -r var _; do
        if [ "$var" != "PATH" ] && [ -n "$var" ]; then
            unset "$var" 2>/dev/null || true
        fi
    done < <(env)
    
    # Carica ambiente originale
    set -a
    source "$ENV_BACKUP_FILE"
    set +a
    
    rm "$ENV_BACKUP_FILE"
    debug "Environment restored and backup file removed"
fi

# Configura XDG_RUNTIME_DIR
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    ADM_UID=$(id -u "$ADM_USER")
    export XDG_RUNTIME_DIR="/run/user/$ADM_UID"
    debug "XDG_RUNTIME_DIR set to: $XDG_RUNTIME_DIR"
fi

# Configura DBUS_SESSION_BUS_ADDRESS
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    debug "DBUS_SESSION_BUS_ADDRESS set to: $DBUS_SESSION_BUS_ADDRESS"
fi

# Assicurati che XDG_RUNTIME_DIR esista e abbia i permessi corretti
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    mkdir -p "$XDG_RUNTIME_DIR"
    chown "$ADM_USER:$ADM_USER" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    debug "Created XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"
fi

log "Starting command: $*"
exec "$@"