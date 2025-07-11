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
# curl -s http://192.168.0.88/frpc-install.sh | bash -s --url=167.71.195.82 --port=57000 --token=xxx

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

#=== Generate frpc.toml with device-specific values
echo "Generating frpc.toml..."
mkdir -p ~/frpc
cat > ~/frpc/frpc.toml <<EOL
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

#=======Create docker-compose.yml
cat > ~/frpc/docker-compose.yml << EOL
services:
  frpc:
    image: snowdreamtech/frpc:${FRPC_VERSION}
    container_name: frpc
    restart: always
    volumes:
      - ./frpc.toml:/etc/frp/frpc.toml
    network_mode: host
EOL

#=======Start frpc container
echo "Starting frpc container..."
cd ~/frpc
docker compose up -d

echo "Installation and setup completed successfully!"
