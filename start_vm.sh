#!/usr/bin/env bash
#
# run-test-vm.sh - Boot a VM from an existing disk image (no cloning)
#
# Usage:
#   ./run-test-vm.sh <image.qcow2> [options]
#
# Positional:
#   image.qcow2          Path to an existing qcow2 disk image to boot (required)
#
# Options:
#   -n, --name NAME      Name for the VM (default: test-$(timestamp))
#   -m, --memory MB      Memory in MB (default: 4096)
#   -c, --cpus N         Number of CPU cores (default: 2)
#   -p, --ssh-port PORT  SSH port forwarding (default: 2222)
#       --efi PATH       Path to EFI/UEFI firmware (QEMU_EFI.fd).
#                        Default: ./efi/QEMU_EFI.fd (relative to repo root)
#   -h, --help           Show this help message
#
# Example:
#   ./run-test-vm.sh ~/vm-images/ubuntu.qcow2
#   ./run-test-vm.sh ~/vm-images/ubuntu.qcow2 -n mytest -m 8192
#   ./run-test-vm.sh ~/vm-images/ubuntu.qcow2 --efi ./efi/QEMU_EFI.fd

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

QEMU_BASE_DIR="${QEMU_BASE_DIR:-$HOME/_qemu_vm}"
PCSETUP_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# EFI default (repo-first)
REPO_EFI_DEFAULT="$PCSETUP_REPO/efi/QEMU_EFI.fd"

# Defaults
VM_NAME="test-$(date +%Y%m%d-%H%M%S)"
MEMORY=4096
CPUS=2
SSH_PORT=2222

# Optional override; defaults to repo EFI
UEFI_FIRMWARE="$REPO_EFI_DEFAULT"

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    sed -n '3,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "x86_64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) log_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

detect_os() {
    case "$(uname -s)" in
        Linux) echo "linux" ;;
        Darwin) echo "macos" ;;
        *) log_error "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac
}

check_dependencies() {
    local arch os
    arch=$(detect_arch)
    os=$(detect_os)

    # Check QEMU
    if [[ "$arch" == "x86_64" ]]; then
        if ! command -v qemu-system-x86_64 &>/dev/null; then
            log_error "qemu-system-x86_64 not found. Install QEMU first."
            [[ "$os" == "linux" ]] && echo "  sudo apt install qemu-kvm qemu-utils"
            [[ "$os" == "macos" ]] && echo "  brew install qemu"
            exit 1
        fi
    else
        if ! command -v qemu-system-aarch64 &>/dev/null; then
            log_error "qemu-system-aarch64 not found. Install QEMU first."
            [[ "$os" == "linux" ]] && echo "  sudo apt install qemu-system-aarch64 qemu-utils"
            [[ "$os" == "macos" ]] && echo "  brew install qemu"
            exit 1
        fi
    fi

    # Check UEFI firmware for ARM (repo-first default, user-overridable via --efi)
    if [[ "$arch" == "arm64" ]]; then
        if [[ ! -f "$UEFI_FIRMWARE" ]]; then
            log_error "UEFI firmware not found: $UEFI_FIRMWARE"
            log_error "Provide it via --efi <path> or place it at: $REPO_EFI_DEFAULT"
            exit 1
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments (positional image first; options after)
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    log_error "Missing required positional argument: <image.qcow2>"
    echo ""
    usage
fi

IMAGE_PATH="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -p|--ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --efi)
            UEFI_FIRMWARE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    local arch os
    arch=$(detect_arch)
    os=$(detect_os)

    log_info "Detecting system: $os / $arch"
    check_dependencies

    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image not found: $IMAGE_PATH"
        exit 1
    fi

    # Show configuration and prompt for confirmation
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Start VM From Existing Disk"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  ${CYAN}VM Configuration:${NC}"
    echo "    Name:           $VM_NAME"
    echo "    Memory:         ${MEMORY}MB"
    echo "    CPUs:           $CPUS"
    echo "    SSH Port:       $SSH_PORT"
    echo ""
    echo "  ${CYAN}Paths:${NC}"
    echo "    Disk image:     $IMAGE_PATH"
    echo "    Shared repo:    $PCSETUP_REPO"
    echo ""
    echo "  ${CYAN}System:${NC}"
    echo "    Architecture:   $arch"
    echo "    OS:             $os"
    if [[ "$arch" == "arm64" ]]; then
        echo "    UEFI firmware:  $UEFI_FIRMWARE"
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    echo -n "  Start this VM? (Y/n): "
    read -r confirm
    if [[ "${confirm,,}" == "n" || "${confirm,,}" == "no" ]]; then
        log_info "Cancelled by user"
        exit 0
    fi
    echo ""

    # Print connection info
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  VM: $VM_NAME"
    echo "  Memory: ${MEMORY}MB | CPUs: $CPUS"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  SSH access (after boot):  ssh -p $SSH_PORT user@localhost"
    echo ""
    echo "  Inside VM, mount pcsetup repo:"
    echo "    sudo mkdir -p /mnt/pcsetup ~/dev/pcsetup/_local"
    echo "    sudo mount -t 9p -o trans=virtio,version=9p2000.L pcsetup /mnt/pcsetup"
    echo "    cp -r /mnt/pcsetup/pcsetup ~/dev/pcsetup"
    echo "    cp /mnt/pcsetup/_local/spec.pcsetup-test.yaml ~/dev/pcsetup/_local/"
    echo ""
    echo "  Run pcsetup:"
    echo "    cd ~/dev/pcsetup"
    echo "    python3 -m pcsetup spec _local/machines/spec.pcsetup-test.yaml -o out/plan.yaml"
    echo "    sudo python3 -m pcsetup execute -i ~/plan.yaml"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Build QEMU command
    local qemu_cmd
    local common_opts=(
        -name "$VM_NAME"
        -m "$MEMORY"
        -smp "$CPUS,cores=$CPUS"
        -drive "file=$IMAGE_PATH,format=qcow2,if=virtio,cache=writeback"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
        -device virtio-net-pci,netdev=net0
        -device qemu-xhci
        -device usb-kbd
        -device usb-tablet
        -virtfs "local,path=$PCSETUP_REPO,mount_tag=pcsetup,security_model=mapped-xattr,id=pcsetup"
    )

    if [[ "$arch" == "x86_64" ]]; then
        qemu_cmd="qemu-system-x86_64"
        common_opts+=(
            -cpu host
            -vga virtio
        )
        if [[ "$os" == "linux" ]]; then
            common_opts+=(-enable-kvm -display gtk,grab-on-hover=on)
        else
            common_opts+=(-accel hvf -display cocoa)
        fi
    else
        qemu_cmd="qemu-system-aarch64"
        common_opts+=(
            -machine virt,highmem=on
            -accel hvf
            -cpu host
            -bios "$UEFI_FIRMWARE"
            -device virtio-gpu-pci
        )
        if [[ "$os" == "linux" ]]; then
            common_opts+=(-display gtk,grab-on-hover=on)
        else
            common_opts+=(-display cocoa)
        fi
    fi

    log_info "Starting VM..."
    echo ""

    "$qemu_cmd" "${common_opts[@]}"

    log_ok "VM shut down"
}

main "$@"