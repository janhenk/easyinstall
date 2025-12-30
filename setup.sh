#!/bin/bash

#############################################
# Automated Docker Server Setup Script
# For Ubuntu Server 24.04.3 LTS
# With CasaOS, NVIDIA drivers, and dual-drive setup
#############################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to prompt for confirmation
confirm() {
    read -p "$1 (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Welcome message
echo "============================================"
echo "  Docker Server Automated Setup"
echo "============================================"
echo ""
print_warning "This script will:"
echo "  1. Update system packages"
echo "  2. Configure second drive for Docker storage"
echo "  3. Install NVIDIA drivers (570)"
echo "  4. Install Docker and NVIDIA Container Toolkit"
echo "  5. Install CasaOS"
echo "  6. Configure everything automatically"
echo ""

if ! confirm "Do you want to continue?"; then
    print_error "Setup cancelled"
    exit 0
fi

check_root

# Step 1: Update system
print_status "Updating system packages..."
apt update
apt upgrade -y
print_success "System updated"

# Step 2: Get current IP address
echo ""
print_status "Current network configuration:"
ip -br addr show
echo ""

# Get current IP from DHCP
SERVER_IP=$(hostname -I | awk '{print $1}')
print_success "Server IP address: $SERVER_IP"
print_status "Using DHCP (configured via router)"

# Step 3: Configure second drive
echo ""
print_status "Scanning for available drives..."
lsblk -d -o NAME,SIZE,TYPE | grep disk

echo ""
print_warning "Your OS drive should be around 238GB"
print_warning "Your storage drive should be around 931GB"
echo ""

if confirm "Do you want to set up the second drive (931GB) for Docker storage?"; then
    read -p "Enter the device name for the 931GB drive (e.g., sdb): " STORAGE_DEVICE
    
    print_warning "This will ERASE ALL DATA on /dev/$STORAGE_DEVICE"
    if confirm "Are you absolutely sure?"; then
        print_status "Partitioning /dev/$STORAGE_DEVICE..."
        
        # Create partition table and partition
        parted -s /dev/$STORAGE_DEVICE mklabel gpt
        parted -s /dev/$STORAGE_DEVICE mkpart primary ext4 0% 100%
        
        # Wait for partition to be recognized
        sleep 2
        
        # Format the partition
        print_status "Formatting /dev/${STORAGE_DEVICE}1..."
        mkfs.ext4 -F /dev/${STORAGE_DEVICE}1
        e2label /dev/${STORAGE_DEVICE}1 docker-storage
        
        # Create mount point
        mkdir -p /mnt/docker-storage
        
        # Get UUID
        UUID=$(blkid -s UUID -o value /dev/${STORAGE_DEVICE}1)
        
        # Add to fstab
        print_status "Configuring automatic mounting..."
        echo "UUID=$UUID /mnt/docker-storage ext4 defaults 0 2" >> /etc/fstab
        
        # Mount the drive
        mount -a
        
        # Set permissions
        chown -R root:root /mnt/docker-storage
        chmod 755 /mnt/docker-storage
        
        print_success "Storage drive configured and mounted at /mnt/docker-storage"
        
        STORAGE_CONFIGURED=true
    else
        print_warning "Skipping storage drive setup"
        STORAGE_CONFIGURED=false
    fi
else
    print_warning "Skipping storage drive setup"
    STORAGE_CONFIGURED=false
fi

# Step 4: Install NVIDIA drivers
echo ""
if confirm "Do you want to install NVIDIA drivers (required for GPU/AI workloads)?"; then
    print_status "Adding graphics drivers PPA..."
    add-apt-repository ppa:graphics-drivers/ppa -y
    apt update
    
    print_status "Installing NVIDIA driver 570 (this may take a while)..."
    apt install -y nvidia-driver-570
    
    print_success "NVIDIA drivers installed"
    print_warning "System will need to reboot to load NVIDIA drivers"
    NVIDIA_INSTALLED=true
else
    print_warning "Skipping NVIDIA driver installation"
    NVIDIA_INSTALLED=false
fi

# Step 5: Install Docker
echo ""
print_status "Installing Docker..."

# Install prerequisites
apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker
systemctl enable docker
systemctl start docker

print_success "Docker installed"

# Configure Docker to use storage drive if configured
if [ "$STORAGE_CONFIGURED" = true ]; then
    print_status "Configuring Docker to use storage drive..."
    
    # Stop Docker
    systemctl stop docker
    
    # Create Docker directory on storage drive
    mkdir -p /mnt/docker-storage/docker
    
    # Configure Docker daemon
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "/mnt/docker-storage/docker"
}
EOF
    
    # Start Docker
    systemctl start docker
    
    print_success "Docker configured to use /mnt/docker-storage/docker"
fi

# Step 6: Install NVIDIA Container Toolkit (if NVIDIA drivers were installed)
if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    print_status "Installing NVIDIA Container Toolkit..."
    
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Use the modern GPG key method instead of deprecated apt-key
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    apt update
    apt install -y nvidia-container-toolkit
    
    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    
    print_success "NVIDIA Container Toolkit installed"
fi

# Step 7: Install CasaOS
echo ""
print_status "Installing CasaOS (this may take 5-10 minutes)..."
curl -fsSL https://get.casaos.io | bash

print_success "CasaOS installed"

# Step 8: Install additional useful tools
echo ""
if confirm "Do you want to install additional useful tools (htop, nano, etc.)?"; then
    print_status "Installing additional tools..."
    apt install -y htop nano net-tools wget curl git
    print_success "Additional tools installed"
fi

# Final summary
echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
print_success "Your Docker server is ready!"
echo ""
echo "Access Information:"
echo "  - CasaOS Web UI: http://$SERVER_IP"
echo "  - Server IP: $SERVER_IP"
echo ""

if [ "$STORAGE_CONFIGURED" = true ]; then
    echo "Storage Configuration:"
    echo "  - Docker storage: /mnt/docker-storage/docker"
    df -h | grep docker-storage
    echo ""
fi

if [ "$NVIDIA_INSTALLED" = true ]; then
    print_warning "IMPORTANT: System needs to reboot to load NVIDIA drivers"
    echo ""
    if confirm "Do you want to reboot now?"; then
        print_status "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        print_warning "Please reboot manually to activate NVIDIA drivers"
        echo "After reboot, run: nvidia-smi"
    fi
else
    echo "Next Steps:"
    echo "  1. Open http://$SERVER_IP in your browser"
    echo "  2. Complete CasaOS initial setup"
    echo "  3. Install apps from the CasaOS App Store"
    echo ""
fi

echo "============================================"
