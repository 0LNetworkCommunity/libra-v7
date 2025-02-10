#!/bin/sh
set -e

# Install dependencies silently
apt install -y curl

# Display version
echo "Libra binary info:"
which libra
libra version
sleep 3

# Download framework
echo "Downloading framework..."
mkdir -p /usr/libra/framework/releases/
curl -sL https://github.com/0LNetworkCommunity/libra-framework/releases/download/7.0.3/release-7.0.3.mrb -o /usr/libra/framework/releases/head.mrb

echo "Starting Libra node: $ME"
export MODE_0L="TESTNET"
libra ops genesis testnet --framework-mrb-path /usr/libra/framework/releases/head.mrb --me "$ME" --host-list alice:6180 --host-list bob:6180 --host-list carol:6180 

# PATCH: open ports in node config
echo "Opening ports in node config..."
sed -i 's/127.0.0.1/0.0.0.0/g' $HOME/.libra/validator.yaml

echo "Starting up the libra node..."
RUST_LOG=INFO libra node
