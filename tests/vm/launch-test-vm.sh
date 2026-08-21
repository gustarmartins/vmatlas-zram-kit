#!/usr/bin/env bash
# ==============================================================================
# vmatlas-zram-kit: Automated Arch Linux Test VM Launcher (KVM / QEMU)
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/vmatlas-test-vm"
VM_RUN_DIR="$SCRIPT_DIR/.run"

# Defaults
RAM="16G"
SMP="4"
SSH_PORT="2222"
WB_SIZE="8G"
DISPLAY_MODE="nographic" # nographic | gtk | sdl
RESET=0

# Styling
if [ -t 1 ]; then
    BOLD=$'\033[1m'
    CYAN=$'\033[36m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
    RST=$'\033[0m'
else
    BOLD='' CYAN='' GREEN='' YELLOW='' RED='' RST=''
fi

info()    { printf "${CYAN}[*] %s${RST}\n" "$*"; }
success() { printf "${GREEN}[+] %s${RST}\n" "$*"; }
warn()    { printf "${YELLOW}[!] %s${RST}\n" "$*"; }
die()     { printf "${RED}[-] ERROR: %s${RST}\n" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}vmatlas-zram-kit Test VM Launcher${RST}

Usage: ./tests/vm/launch-test-vm.sh [options]

Options:
  --ram <size>           Memory allocated to VM (e.g. 4G, 8G, 16G, 32G). Default: 16G
  --smp <cores>          Number of virtual CPU cores. Default: 4
  --ssh-port <port>      Host port to forward for SSH. Default: 2222
  --wb-size <size>       Size of virtual raw writeback NVMe/virtio drive. Default: 8G
  --gui                  Launch QEMU with graphical window instead of serial console
  --reset                Reset VM instance overlay and re-create clean state
  -h, --help             Show this help message

Inside the VM:
  - User: ${BOLD}root${RST} (password: ${BOLD}root${RST}) or ${BOLD}arch${RST} (password: ${BOLD}arch${RST}, passwordless sudo)
  - Kit Repository: Mounted at ${BOLD}/root/vmatlas-zram-kit${RST}
  - Secondary Raw Disk: ${BOLD}/dev/vdb${RST} (for testing writeback partition wizard)
  - Exit Console: Press ${BOLD}Ctrl-A${RST} then ${BOLD}X${RST}, or run ${BOLD}poweroff${RST}
  - SSH Access: ${BOLD}ssh -p 2222 root@localhost${RST}

EOF
}

# Parse options
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ram) RAM="${2:-16G}"; shift 2 ;;
        --smp) SMP="${2:-4}"; shift 2 ;;
        --ssh-port) SSH_PORT="${2:-2222}"; shift 2 ;;
        --wb-size) WB_SIZE="${2:-8G}"; shift 2 ;;
        --gui) DISPLAY_MODE="gtk"; shift ;;
        --reset) RESET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

# Prerequisites check
check_prerequisites() {
    info "Checking host virtualization tools..."
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 is required. Please install 'qemu-desktop' or 'qemu-base'."
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required."
    
    if command -v genisoimage >/dev/null 2>&1; then
        ISO_GEN="genisoimage"
    elif command -v mkisofs >/dev/null 2>&1; then
        ISO_GEN="mkisofs"
    else
        die "genisoimage or mkisofs is required to build cloud-init seed ISO."
    fi

    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        warn "/dev/kvm is not accessible with read/write permissions. VM will run without hardware acceleration (slow)."
        KVM_FLAG=""
    else
        KVM_FLAG="-enable-kvm"
        success "KVM hardware acceleration is available."
    fi
}

# Fetch base cloud image
fetch_base_image() {
    mkdir -p "$CACHE_DIR"
    local base_img="$CACHE_DIR/Arch-Linux-x86_64-cloudimg.qcow2"
    local url="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"

    if [ ! -f "$base_img" ]; then
        info "Downloading official Arch Linux cloud image (~700MB)..."
        curl -fSL -o "$base_img.tmp" "$url" || die "failed to download Arch Linux cloud image from $url"
        mv "$base_img.tmp" "$base_img"
        success "Base image downloaded and cached at $base_img"
    else
        info "Using cached base image: $base_img"
    fi
}

# Prepare VM overlay and cloud-init seed
prepare_instance() {
    mkdir -p "$VM_RUN_DIR"
    local base_img="$CACHE_DIR/Arch-Linux-x86_64-cloudimg.qcow2"
    local instance_img="$VM_RUN_DIR/test-os.qcow2"
    local seed_iso="$VM_RUN_DIR/seed.iso"
    local wb_disk="$VM_RUN_DIR/writeback-disk.raw"

    if [ "$RESET" -eq 1 ] || [ ! -f "$instance_img" ]; then
        info "Creating fresh copy-on-write overlay disk ($instance_img)..."
        rm -f "$instance_img"
        qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$instance_img" 30G >/dev/null
    fi

    if [ "$RESET" -eq 1 ] || [ ! -f "$wb_disk" ]; then
        info "Creating virtual raw secondary writeback disk ($WB_SIZE)..."
        rm -f "$wb_disk"
        qemu-img create -f raw "$wb_disk" "$WB_SIZE" >/dev/null
    fi

    # Build Cloud-Init seed configuration
    info "Generating cloud-init user-data seed..."
    cat >"$VM_RUN_DIR/user-data" <<'EOF'
#cloud-config
ssh_pwauth: true
chpasswd:
  list: |
    root:root
    arch:arch
  expire: false

users:
  - name: arch
    gecos: Arch User
    primary_group: wheel
    groups: [wheel, kvm]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

packages:
  - zram-generator
  - procps-ng
  - util-linux
  - gawk
  - python
  - git
  - gptfdisk
  - sudo
  - curl
  - nano

runcmd:
  - systemctl enable --now sshd
  - mkdir -p /root/vmatlas-zram-kit /home/arch/vmatlas-zram-kit
  - mount -t 9p -o trans=virtio vmatlas /root/vmatlas-zram-kit || true
  - mount -t 9p -o trans=virtio vmatlas /home/arch/vmatlas-zram-kit || true
  - echo "vmatlas-zram-kit test environment ready." > /etc/motd
EOF

    cat >"$VM_RUN_DIR/meta-data" <<EOF
instance-id: vmatlas-test-$(date +%s)
local-hostname: vmatlas-test-vm
EOF

    "$ISO_GEN" -output "$seed_iso" -volid cidata -joliet -rock \
        "$VM_RUN_DIR/user-data" "$VM_RUN_DIR/meta-data" >/dev/null 2>&1
}

# Launch QEMU
launch_vm() {
    local instance_img="$VM_RUN_DIR/test-os.qcow2"
    local seed_iso="$VM_RUN_DIR/seed.iso"
    local wb_disk="$VM_RUN_DIR/writeback-disk.raw"

    local qemu_display=()
    if [ "$DISPLAY_MODE" = "nographic" ]; then
        qemu_display=(-nographic -serial mon:stdio)
    else
        qemu_display=(-display gtk,gl=on -device virtio-vga-gl)
    fi

    cat <<EOF
================================================================================
  ${BOLD}${CYAN}VMATLAS-ZRAM-KIT TEST VM INSTANCE${RST}
================================================================================
  - Virtual RAM:          ${BOLD}${GREEN}${RAM}${RST} (Test Host Sizing)
  - Virtual Cores:        ${BOLD}${SMP} vCPUs${RST}
  - Secondary Raw Disk:   ${BOLD}/dev/vdb${RST} (${WB_SIZE} for writeback testing)
  - Shared Repository:    ${BOLD}/root/vmatlas-zram-kit${RST}
  - Login Credentials:    ${BOLD}root${RST} / ${BOLD}root${RST}  or  ${BOLD}arch${RST} / ${BOLD}arch${RST}
  - SSH Port Forward:     ${BOLD}ssh -p ${SSH_PORT} root@localhost${RST}
  - Exit QEMU:            Press ${BOLD}Ctrl-A${RST} then ${BOLD}X${RST}, or run ${BOLD}poweroff${RST}
================================================================================
EOF

    info "Starting QEMU VM..."
    qemu-system-x86_64 \
        ${KVM_FLAG} \
        -cpu host \
        -smp "$SMP" \
        -m "$RAM" \
        -drive file="$instance_img",if=virtio,format=qcow2 \
        -drive file="$seed_iso",media=cdrom \
        -drive file="$wb_disk",if=virtio,format=raw \
        -virtfs local,path="$REPO_ROOT",mount_tag=vmatlas,security_model=none,id=vmatlas \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::"${SSH_PORT}"-:22 \
        "${qemu_display[@]}"
}

check_prerequisites
fetch_base_image
prepare_instance
launch_vm
