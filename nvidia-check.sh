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
    log "Removing existing NVIDIA packages..."
    local existing_packages
    existing_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {print $2}')
    if [ -n "$existing_packages" ]; then
        apt-get purge -qqy "$existing_packages" >/dev/null 2>&1 || warning "Failed to purge some packages"
    fi
    apt-get autoremove -qqy >/dev/null 2>&1

    log "Installing $package_name=$install_version..."
    apt-get install -qqy --no-install-recommends "$package_name=$install_version" \
        libnvidia-gl-"$major_version" \
        nvidia-dkms-"$major_version" \
        nvidia-utils-"$major_version" \
        > /dev/null 2>&1 || {
            error "Failed to install NVIDIA packages. Check repository availability."
            return 1
        }

    success "NVIDIA driver $install_version installed successfully."
}

# Funzione di troubleshooting
troubleshoot() {
    log "Starting NVIDIA troubleshooting..."

    echo "=== Diagnostics ==="

    # Check CUDA
    if command -v nvidia-smi >/dev/null 2>&1; then
        success "nvidia-smi is available."
        nvidia-smi
    else
        warning "nvidia-smi is not found. Drivers might not be installed correctly."
    fi

    # Check OpenGL
    if command -v glxinfo >/dev/null 2>&1; then
        success "glxinfo is available."
        if glxinfo -B 2>&1 | grep "OpenGL renderer string" | grep -q "NVIDIA"; then
            success "OpenGL renderer is NVIDIA."
        else
            warning "OpenGL renderer is not NVIDIA."
            glxinfo -B | grep "OpenGL renderer"
        fi
    else
        warning "glxinfo is not found. Install 'mesa-utils' for full diagnostics."
    fi

    # Check Vulkan
    if command -v vulkaninfo >/dev/null 2>&1; then
        success "vulkaninfo is available."
        if vulkaninfo | grep "apiVersion" >/dev/null 2>&1; then
            success "Vulkan is functional."
        else
            warning "Vulkan is not working properly."
        fi
    else
        warning "vulkaninfo is not found. Install 'vulkan-tools' for full diagnostics."
    fi

    # Check device file permissions
    if [ -c /dev/nvidia0 ] && [ -c /dev/nvidia-uvm ]; then
        success "NVIDIA device files found."
        log "Checking permissions..."
        if [ "$(stat -c '%a' /dev/nvidia0)" = "666" ]; then
            success "/dev/nvidia0 has correct permissions."
        else
            warning "/dev/nvidia0 has incorrect permissions. This can cause issues."
        fi
    else
        warning "NVIDIA device files not found. The container might not be run with '--gpus all'."
    fi

    echo
    success "Troubleshooting complete. Review the output for potential issues."
}

# Funzione di pulizia
clean_nvidia_installation() {
    log "Starting NVIDIA package cleanup..."

    # Rimuovi pacchetti NVIDIA
    local existing_packages
    existing_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {print $2}')

    if [ -n "$existing_packages" ]; then
        log "Found existing packages to remove:"
        echo "$existing_packages" | nl -w2 -s'. '
        echo

        read -p "Proceed with full removal? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Cleanup cancelled."
            return 0
        fi

        log "Purging packages..."
        apt-get purge -qqy $existing_packages >/dev/null 2>&1 || warning "Failed to purge some packages. Trying again."
        apt-get autoremove -qqy >/dev/null 2>&1

        success "NVIDIA packages removed."
    else
        warning "No NVIDIA packages found to clean."
    fi
}

# Main
if [ "$#" -eq 0 ]; then
    show_help
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    check)
        detect_system_info
        detect_host_nvidia
        detect_container_nvidia
        ;;
    list)
        MAJOR_VERSION=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --major)
                    MAJOR_VERSION="$2"
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
            shift
        done
        if [ -z "$MAJOR_VERSION" ]; then
            error "Missing required option: --major"
            show_help
            exit 1
        fi
        list_available_packages "$MAJOR_VERSION"
        ;;
    install)
        TARGET_VERSION=""
        FORCE_INSTALL="false"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --version)
                    TARGET_VERSION="$2"
                    shift
                    ;;
                --force)
                    FORCE_INSTALL="true"
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
            shift
        done
        if [ -z "$TARGET_VERSION" ]; then
            error "Missing required option: --version"
            show_help
            exit 1
        fi
        install_nvidia_version "$TARGET_VERSION" "$FORCE_INSTALL"
        ;;
    troubleshoot)
        troubleshoot
        ;;
    clean)
        clean_nvidia_installation
        ;;
    *)
        error "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac