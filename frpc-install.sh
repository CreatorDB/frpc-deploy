#!/bin/bash

FRPC_VERSION=0.63.0
FRPC_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIHqIaasvJjaOCfFVh2jq+mM97OMSSrh2g5dRYiLaWSj"
FRPS_URL=""
FRPS_PORT=""
FRPS_TOKEN=""
# Get current hostname
HOSTNAME=$(hostname)

# Connect by parameter
# E.g.
# curl -s http://example.com/frpc-install.sh | bash -s --url=example.com --port=57000 --token=xxx

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --url=*) FRPS_URL="${1#*=}" ;;
    --port=*) FRPS_PORT="${1#*=}" ;;
    --token=*) FRPS_TOKEN="${1#*=}" ;;
    *) 
      echo "錯誤：未知參數：$1" 
      exit 1
      ;;
  esac
  shift
done
# Verify all 
[[ -z "$FRPS_URL"  ]] && { echo "err: --url must not be empty"; exit 1; }
[[ -z "$FRPS_PORT"  ]] && { echo "err: --port must not be empty"; exit 1; }
[[ -z "$FRPS_TOKEN" ]] && { echo "err: --token must not be empty"; exit 1; }

# Check if install docker
type docker >/dev/null 2>&1 || {
    echo "Docker is not instaled"
    exit 1
}

if ! docker info >/dev/null 2>&1; then
    cat <<EOF
Docker is not running or your current user is not in docker group.
EOF
fi

# Fetch devices.json and parse it to find hostname and remote_port
echo "Fetching devices.json from frp server..."
DEVICE_FOUND=false
REMOTE_PORT=""
# Use curl to fetch JSON and pipe it to grep/awk for parsing
JSON_CONTENT=$(curl -s http://${FRPS_URL}/devices.json)
if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch devices.json"
    exit 1
fi

# Check if hostname exists and extract remote_port
if echo "$JSON_CONTENT" | grep -q "\"name\": \"$HOSTNAME\""; then
    DEVICE_FOUND=true
    # Get the remote_port from the line following the matching name
    REMOTE_PORT=$(echo "$JSON_CONTENT" | grep -A1 "\"name\": \"$HOSTNAME\"" | grep "remote_port" | awk -F: '{print $2}' | tr -d ' ,}')
    echo "$HOSTNAME found $REMOTE_PORT!"
fi

if [ "$DEVICE_FOUND" = false ]; then
    echo "Error: Hostname $HOSTNAME not found in devices.json"
    exit 1
fi

# Add public key to authorized_keys if not already present
echo "Checking/adding public key to authorized_keys..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ -f ~/.ssh/authorized_keys ]; then
    if ! grep -Fx "$FRPC_PUBLIC_KEY" ~/.ssh/authorized_keys >/dev/null; then
        echo "$FRPC_PUBLIC_KEY" >>~/.ssh/authorized_keys
        echo "Public key added to authorized_keys"
    else
        echo "Public key already exists in authorized_keys, skipping"
    fi
else
    echo "$FRPC_PUBLIC_KEY" >~/.ssh/authorized_keys
    echo "Public key added to new authorized_keys file"
fi
chmod 600 ~/.ssh/authorized_keys

# Determine container name and configuration directory
CONTAINER_NAME="frpc"
CONFIG_DIR=~/frpc

if docker ps -a --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
    read -p "Container '$CONTAINER_NAME' already exists. Do you want to (R)eplace it or (C)reate a new one? [R/C] " -n 1 -r
    echo
    case "$REPLY" in
        c|C)
            i=1
            while docker ps -a --format '{{.Names}}' | grep -qw "frpc-$i"; do
                ((i++))
            done
            CONTAINER_NAME="frpc-$i"
            CONFIG_DIR=~/frpc-$i
            echo "Will create new container '$CONTAINER_NAME' with config in '$CONFIG_DIR'."
            ;;
        r|R)
            echo "Will replace existing container '$CONTAINER_NAME' using config in '$CONFIG_DIR'."
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

#=== Generate frpc.toml with device-specific values
echo "Generating frpc.toml in $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/frpc.toml" <<EOL
# FRP Client Configuration
serverAddr = "$FRPS_URL"
serverPort = $FRPS_PORT
auth.token = "$FRPS_TOKEN"

[[proxies]]
name="ssh-$HOSTNAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $REMOTE_PORT
EOL

#=== Create docker-compose.yml
cat > "$CONFIG_DIR/docker-compose.yml" << EOL
services:
  frpc:
    image: snowdreamtech/frpc:${FRPC_VERSION}
    container_name: ${CONTAINER_NAME}
    restart: always
    volumes:
      - ./frpc.toml:/etc/frp/frpc.toml
    network_mode: host
EOL

# Start frpc container
echo "Starting frpc container..."
cd "$CONFIG_DIR"
docker compose down
docker compose up -d

echo "Installation and setup for ${CONTAINER_NAME} completed successfully!"
