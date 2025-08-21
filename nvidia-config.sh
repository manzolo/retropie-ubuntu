#!/bin/bash
# nvidia-config.sh - Configurazione e troubleshooting NVIDIA

set -euo pipefail

# Configurazione default
DEFAULT_MAJOR_VERSIONS=(550 545 535 525)
UBUNTU_VERSION="24.04"

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

show_help() {
    cat << EOF
NVIDIA Configuration and Troubleshooting Tool

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    check           Check current NVIDIA setup
    list            List available NVIDIA packages
    install         Install specific NVIDIA version
    troubleshoot    Run NVIDIA troubleshooting
    clean           Clean NVIDIA installation

OPTIONS:
    --major VERSION     Specify major version (e.g., 550, 545)
    --version VERSION   Specify full version (e.g., 550.163)
    --force            Force installation
    --help             Show this help

EXAMPLES:
    $0 check                          # Check current setup
    $0 list --major 550              # List packages for driver series 550
    $0 install --version 550.120     # Install specific version
    $0 troubleshoot                  # Run diagnostics
EOF
}

# Rileva informazioni del sistema
detect_system_info() {
    log "Detecting system information..."
    
    echo "=== System Information ==="
    echo "OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo
}

# Rileva driver NVIDIA host
detect_host_nvidia() {
    log "Detecting host NVIDIA driver..."
    
    local host_version=""
    local detection_method=""
    
    # Metodo 1: /proc/driver/nvidia/version
    if [ -f "/proc/driver/nvidia/version" ]; then
        host_version=$(sed -nE 's/.*Module[ \t]+([0-9]+\.[0-9]+).*/\1/p' /proc/driver/nvidia/version | head -n1)
        if [ -n "$host_version" ]; then
            detection_method="/proc/driver/nvidia/version"
        fi
    fi
    
    # Metodo 2: nvidia-smi
    if [ -z "$host_version" ] && command -v nvidia-smi >/dev/null 2>&1; then
        host_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
        if [ -n "$host_version" ]; then
            detection_method="nvidia-smi"
        fi
    fi
    
    # Metodo 3: modinfo
    if [ -z "$host_version" ] && command -v modinfo >/dev/null 2>&1; then
        host_version=$(modinfo nvidia 2>/dev/null | grep '^version:' | awk '{print $2}')
        if [ -n "$host_version" ]; then
            detection_method="modinfo"
        fi
    fi
    
    echo "=== Host NVIDIA Driver ==="
    if [ -n "$host_version" ]; then
        success "Version: $host_version"
        echo "Detection method: $detection_method"
        echo "Major version: $(echo "$host_version" | cut -d. -f1)"
    else
        warning "No NVIDIA driver detected on host"
    fi
    echo
    
    echo "$host_version"
}

# Rileva driver container
detect_container_nvidia() {
    log "Detecting container NVIDIA packages..."
    
    echo "=== Container NVIDIA Packages ==="
    
    local nvidia_packages
    nvidia_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {printf "%-30s %s\n", $2, $3}')
    
    if [ -n "$nvidia_packages" ]; then
        echo "$nvidia_packages"
        
        # Estrai versione principale
        local main_version
        main_version=$(dpkg -l 2>/dev/null | \
            awk '$1 == "ii" && $2 ~ /^libnvidia-gl-/ {print $3}' | \
            sed -nE 's/^([0-9]+(\.[0-9]+)?).*/\1/p' | \
            head -n1)
        
        if [ -n "$main_version" ]; then
            success "Primary driver version: $main_version"
        fi
    else
        warning "No NVIDIA packages found in container"
    fi
    echo
}

# Lista pacchetti disponibili
list_available_packages() {
    local major_version="$1"
    local package_name="libnvidia-gl-$major_version"
    
    log "Listing available packages for major version $major_version..."
    
    # Aggiorna cache se necessario
    if ! apt-cache show "$package_name" >/dev/null 2>&1; then
        log "Updating package cache..."
        apt-get update -qq >/dev/null 2>&1 || {
            error "Failed to update package cache"
            return 1
        }
    fi
    
    echo "=== Available Packages: $package_name ==="
    
    local versions
    versions=$(apt-cache madison "$package_name" 2>/dev/null | awk '{print $3}' | head -10)
    
    if [ -n "$versions" ]; then
        echo "$versions" | nl -w2 -s'. '
        success "Found $(echo "$versions" | wc -l) available versions"
    else
        warning "No packages found for $package_name"
        
        # Suggerisci versioni alternative
        echo
        log "Checking alternative major versions..."
        for alt_major in "${DEFAULT_MAJOR_VERSIONS[@]}"; do
            if [ "$alt_major" != "$major_version" ]; then
                local alt_package="libnvidia-gl-$alt_major"
                if apt-cache show "$alt_package" >/dev/null 2>&1; then
                    local alt_count
                    alt_count=$(apt-cache madison "$alt_package" 2>/dev/null | wc -l)
                    if [ "$alt_count" -gt 0 ]; then
                        echo "  - $alt_package: $alt_count versions available"
                    fi
                fi
            fi
        done
    fi
    echo
}

# Installa versione specifica
install_nvidia_version() {
    local target_version="$1"
    local force_install="${2:-false}"
    local major_version
    major_version=$(echo "$target_version" | cut -d. -f1)
    local package_name="libnvidia-gl-$major_version"
    
    log "Installing NVIDIA driver version $target_version..."
    
    # Trova versione esatta nei repository
    log "Searching for exact package version..."
    
    local available_versions
    available_versions=$(apt-cache madison "$package_name" 2>/dev/null | awk '{print $3}')
    
    local exact_version=""
    local compatible_versions=""
    
    while IFS= read -r version; do
        local version_number
        version_number=$(echo "$version" | sed -nE 's/^([0-9]+(\.[0-9]+)?).*/\1/p')
        
        if [ "$version_number" = "$target_version" ]; then
            exact_version="$version"
            break
        elif [ "$(echo "$version_number" | cut -d. -f1)" = "$(echo "$target_version" | cut -d. -f1)" ]; then
            compatible_versions="$compatible_versions$version\n"
        fi
    done <<< "$available_versions"
    
    echo "=== Installation Plan ==="
    
    if [ -n "$exact_version" ]; then
        success "Found exact version: $exact_version"
        local install_version="$exact_version"
    elif [ -n "$compatible_versions" ]; then
        warning "Exact version not found, compatible versions:"
        echo -e "$compatible_versions" | head -3 | nl -w2 -s'. '
        local install_version
        install_version=$(echo -e "$compatible_versions" | head -n1)
        warning "Will install: $install_version"
    else
        error "No compatible versions found for $target_version"
        return 1
    fi
    
    # Conferma installazione
    if [ "$force_install" != "true" ]; then
        echo
        read -p "Proceed with installation? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Installation cancelled"
            return 0
        fi
    fi
    
    # Rimuovi pacchetti esistenti
    local existing_packages
    existing_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /^libnvidia-/ {print $2}' | tr '\n' ' ')
    
    if [ -n "$existing_packages" ]; then
        log "Removing existing packages: $existing_packages"
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -qqy --auto-remove $existing_packages >/dev/null 2>&1 || {
            warning "Failed to remove some existing packages"
        }
    fi
    
    # Installa nuovo pacchetto
    log "Installing $package_name=$install_version..."
    export DEBIAN_FRONTEND=noninteractive
    
    if apt-get install -qqy --no-install-recommends "$package_name=$install_version" >/dev/null 2>&1; then
        success "Installation completed successfully"
        
        # Verifica installazione
        local installed_version
        installed_version=$(dpkg -l | awk -v pkg="$package_name" '$1 == "ii" && $2 == pkg {print $3}')
        echo "Installed version: $installed_version"
        
        # Cleanup
        apt-get autoremove -qqy >/dev/null 2>&1 || true
        rm -rf /var/lib/apt/lists/*
        
    else
        error "Installation failed"
        return 1
    fi
}

# Troubleshooting NVIDIA
troubleshoot_nvidia() {
    log "Running NVIDIA troubleshooting..."
    
    echo "=== NVIDIA Troubleshooting Report ==="
    echo "Generated: $(date)"
    echo
    
    # 1. Verifica presenza driver host
    local host_version
    host_version=$(detect_host_nvidia)
    
    # 2. Verifica container
    detect_container_nvidia
    
    # 3. Verifica mount esterni
    echo "=== External Mounts ==="
    local nvidia_mounts=()
    for mount_path in "/usr/local/nvidia/lib" "/usr/local/nvidia/lib64" "/nvidia"; do
        if [ -d "$mount_path" ]; then
            nvidia_mounts+=("$mount_path")
            success "Found: $mount_path"
            ls -la "$mount_path" | head -3
        fi
    done
    
    if [ ${#nvidia_mounts[@]} -eq 0 ]; then
        warning "No external NVIDIA mounts found"
    fi
    echo
    
    # 4. Verifica variabili d'ambiente
    echo "=== Environment Variables ==="
    local nvidia_vars=(
        "NVIDIA_VISIBLE_DEVICES"
        "NVIDIA_DRIVER_CAPABILITIES" 
        "__GLX_VENDOR_LIBRARY_NAME"
        "LD_LIBRARY_PATH"
    )
    
    for var in "${nvidia_vars[@]}"; do
        if [ -n "${!var:-}" ]; then
            success "$var=${!var}"
        else
            warning "$var is not set"
        fi
    done
    echo
    
    # 5. Test OpenGL
    echo "=== OpenGL Test ==="
    if command -v glxinfo >/dev/null 2>&1; then
        local gl_renderer
        gl_renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -n1)
        if [[ "$gl_renderer" =~ NVIDIA ]]; then
            success "$gl_renderer"
        else
            warning "OpenGL renderer: $gl_renderer"
        fi
    else
        warning "glxinfo not available (install mesa-utils)"
    fi
    echo
    
    # 6. Test CUDA (se disponibile)
    echo "=== CUDA Test ==="
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            success "nvidia-smi working"
            nvidia-smi -L 2>/dev/null || warning "Could not list GPU devices"
        else
            error "nvidia-smi failed"
        fi
    else
        warning "nvidia-smi not available"
    fi
    echo
    
    # 7. Verifica device nodes
    echo "=== Device Nodes ==="
    local nvidia_devices=(
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
    )
    
    for device in "${nvidia_devices[@]}"; do
        if [ -e "$device" ]; then
            success "Found: $device"
        else
            warning "Missing: $device"
        fi
    done
    echo
    
    # 8. Raccomandazioni
    echo "=== Recommendations ==="
    
    if [ -z "$host_version" ]; then
        echo "• No host NVIDIA driver detected - install NVIDIA driver on host system"
    fi
    
    if [ ${#nvidia_mounts[@]} -eq 0 ] && [ -n "$host_version" ]; then
        echo "• Consider mounting host NVIDIA libraries for better compatibility:"
        echo "  -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:ro"
    fi
    
    if [ -z "${NVIDIA_VISIBLE_DEVICES:-}" ]; then
        echo "• Set NVIDIA_VISIBLE_DEVICES=all environment variable"
    fi
    
    if [ -z "${NVIDIA_DRIVER_CAPABILITIES:-}" ]; then
        echo "• Set NVIDIA_DRIVER_CAPABILITIES=all environment variable"
    fi
    
    echo
    log "Troubleshooting completed"
}

# Pulizia installazione NVIDIA
clean_nvidia() {
    log "Cleaning NVIDIA installation..."
    
    echo "=== NVIDIA Cleanup ==="
    
    # Lista pacchetti da rimuovere
    local nvidia_packages
    nvidia_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {print $2}' | tr '\n' ' ')
    
    if [ -n "$nvidia_packages" ]; then
        echo "Packages to remove:"
        echo "$nvidia_packages" | tr ' ' '\n' | nl -w2 -s'. '
        echo
        
        read -p "Remove all NVIDIA packages? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Removing NVIDIA packages..."
            export DEBIAN_FRONTEND=noninteractive
            
            if apt-get purge -qqy --auto-remove $nvidia_packages >/dev/null 2>&1; then
                success "NVIDIA packages removed successfully"
            else
                error "Failed to remove some packages"
            fi
            
            # Cleanup aggiuntivo
            apt-get autoremove -qqy >/dev/null 2>&1 || true
            apt-get autoclean -qqy >/dev/null 2>&1 || true
            rm -rf /var/lib/apt/lists/*
            
            # Rimuovi file di configurazione
            rm -f /etc/ld.so.conf.d/nvidia.conf
            ldconfig
            
            success "Cleanup completed"
        else
            log "Cleanup cancelled"
        fi
    else
        warning "No NVIDIA packages found to remove"
    fi
}

# Comando check
cmd_check() {
    detect_system_info
    detect_host_nvidia >/dev/null
    detect_container_nvidia
}

# Comando list
cmd_list() {
    local major_version="${1:-550}"
    list_available_packages "$major_version"
}

# Comando install
cmd_install() {
    local version="$1"
    local force="${2:-false}"
    
    if [ -z "$version" ]; then
        error "Version not specified. Use --version option."
        return 1
    fi
    
    install_nvidia_version "$version" "$force"
}

# Parse argomenti
parse_args() {
    local command=""
    local major_version=""
    local version=""
    local force="false"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            check|list|install|troubleshoot|clean)
                command="$1"
                shift
                ;;
            --major)
                major_version="$2"
                shift 2
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --force)
                force="true"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Esegui comando
    case "$command" in
        check)
            cmd_check
            ;;
        list)
            cmd_list "${major_version:-550}"
            ;;
        install)
            cmd_install "$version" "$force"
            ;;
        troubleshoot)
            troubleshoot_nvidia
            ;;
        clean)
            clean_nvidia
            ;;
        "")
            error "No command specified"
            show_help
            exit 1
            ;;
        *)
            error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Main
main() {
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    parse_args "$@"
}

# Controlla se viene eseguito direttamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
