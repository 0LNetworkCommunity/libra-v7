# Libra Framework Testnet in a Bottle

## Quick Start

```bash
# Install container runtime (example: Docker on Ubuntu)
sudo ./container/install_runtime.sh
sudo usermod -aG docker $USER  # For Docker (similar group setup needed for other runtimes)
# Log out and log back in!

# Get the code & start testnet
cd $HOME
git clone https://github.com/0LNetworkCommunity/libra-framework
cd libra-framework/container
docker compose up -d   # or: docker compose up -d

# View logs as it starts up
docker compose logs -f --tail 100  # or: docker compose logs -f --tail 100
```

## Node Configuration

The testnet consists of three validator nodes with the following exposed ports:

| Node    | RPC Port | Metrics Port |
|---------|----------|--------------|
| Alice   | 8280     | 9201         |
| Bob     | 8380     | 9301         |
| Carol   | 8480     | 9401         |

Access endpoints:
- RPC endpoint: `http://localhost:8280/v1`
- Metrics endpoint: `http://localhost:9201/metrics`

## Prerequisites

### Container Runtime Installation (Ubuntu)

1. Install container runtime:
```bash
sudo ./container/install_runtime.sh
```

2. Add your user to the appropriate group (example for Docker):
```bash
sudo usermod -aG docker $USER
```

3. **Important**: Log out and log back in for the group changes to take effect.

4. Verify installation:
```bash
docker run hello-world  # or: docker run hello-world
```

## Managing the Testnet

### Start the Network
```bash
cd libra-framework/container
docker compose up -d  # or: docker compose up -d
```

### Monitor the Network

View all node logs:
```bash
docker compose logs -f --tail 100  # or: docker compose logs -f --tail 100
```

View individual node logs:
```bash
docker logs -f alice --tail 100  # or: docker logs -f alice --tail 100
docker logs -f bob --tail 100    # or: docker logs -f bob --tail 100
docker logs -f carol --tail 100  # or: docker logs -f carol --tail 100
```

### Stop the Network

Stop while preserving data:
```bash
docker compose down  # or: docker compose down
```

Stop and remove all data:
```bash
docker compose down -v  # or: docker compose down -v
```