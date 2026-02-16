#!/bin/bash

# Script to install Docker and Kind on Ubuntu
# No configuration or setup - just installation
# Skips installation if already installed

set -e

echo "=========================================="
echo "Docker and Kind Installation Script"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo"
    exit 1
fi

# Check if Docker is installed
DOCKER_INSTALLED=false
if command -v docker &> /dev/null; then
    DOCKER_INSTALLED=true
    echo "✓ Docker is already installed"
    docker --version
    echo ""
else
    echo "Docker not found. Installing..."
    
    # Update package index
    echo "[1/4] Updating package index..."
    apt-get update -qq

    # Install prerequisites
    echo "[2/4] Installing prerequisites..."
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    echo "[3/4] Adding Docker GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    echo "[4/4] Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    echo "✓ Docker installed successfully"
    docker --version
    echo ""
fi

# Check if Kind is installed
KIND_INSTALLED=false
if command -v kind &> /dev/null; then
    KIND_INSTALLED=true
    echo "✓ Kind is already installed"
    kind --version
    echo ""
else
    echo "Kind not found. Installing..."
    
    # Install Kind
    echo "Downloading Kind v0.20.0..."
    curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x /usr/local/bin/kind
    
    echo "✓ Kind installed successfully"
    kind --version
    echo ""
fi

echo "=========================================="
if [ "$DOCKER_INSTALLED" = true ] && [ "$KIND_INSTALLED" = true ]; then
    echo "All tools were already installed!"
else
    echo "Installation Complete!"
fi
echo "=========================================="
echo ""
echo "Current versions:"
docker --version
kind --version
echo ""
if [ "$DOCKER_INSTALLED" = false ]; then
    echo "Note: You may need to log out and back in for Docker group permissions to take effect."
fi
