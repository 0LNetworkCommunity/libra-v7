#!/bin/bash

# test if jq and curl are installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed, installing..."
    apt update && apt install -y jq
fi

if ! command -v curl &> /dev/null; then
    echo "curl is not installed, installing..."
    apt update && apt install -y curl
fi

# Fetch metrics for each node
alice_connections=$(curl -s 127.0.0.1:9201/metrics | grep "_connections" || echo "Not available")
alice_version=$(curl -s 127.0.0.1:8280/v1 | jq .ledger_version 2>/dev/null || echo "Not available")

bob_connections=$(curl -s 127.0.0.1:9301/metrics | grep "_connections" || echo "Not available")
bob_version=$(curl -s 127.0.0.1:8380/v1 | jq .ledger_version 2>/dev/null || echo "Not available")

carol_connections=$(curl -s 127.0.0.1:9401/metrics | grep "_connections" || echo "Not available")
carol_version=$(curl -s 127.0.0.1:8480/v1 | jq .ledger_version 2>/dev/null || echo "Not available")

# Print results
printf "\nTestnet Status:\n\n"
printf "%-15s %-60s %-15s\n" "Node" "Connections" "Version"
printf "%-15s %-60s %-15s\n" "----" "-----------" "-------"
printf "%-15s %-60s %-15s\n" "Alice" "${alice_connections:-Not available}" "${alice_version:-Not available}"
printf "%-15s %-60s %-15s\n" "Bob" "${bob_connections:-Not available}" "${bob_version:-Not available}"
printf "%-15s %-60s %-15s\n" "Carol" "${carol_connections:-Not available}" "${carol_version:-Not available}"
printf "\n"
