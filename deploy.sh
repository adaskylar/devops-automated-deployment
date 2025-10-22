#!/bin/bash

# ==========================================
# Automated Deployment Script (Stage 1)
# Author: Adaobi Ibekwe
# ==========================================

# Enable strict mode
set -euo pipefail

# Create a timestamped log file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "=========================================="
echo "🚀 Starting Automated Deployment"
echo "=========================================="

# -------- Collect User Input --------
read -p "Enter Git Repository URL: " GIT_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter Remote Server Username: " SSH_USER
read -p "Enter Remote Server IP Address: " SERVER_IP
read -p "Enter SSH Key Path: " SSH_KEY
read -p "Enter Application Port (e.g., 8080): " APP_PORT

echo "✅ User input collected successfully."

# -------- Step 2: Clone or Update Repository --------
echo "=========================================="
echo "📦 Cloning Repository..."
echo "=========================================="

# Extract repo name from URL
REPO_NAME=$(basename -s .git "$GIT_URL")

# If the directory already exists, pull latest changes
if [ -d "$REPO_NAME" ]; then
    echo "Repository already exists. Pulling latest changes..."
    cd "$REPO_NAME"
    git pull origin "$BRANCH"
else
    echo "Cloning repository..."
    git clone -b "$BRANCH" "https://${PAT}@${GIT_URL#https://}" || {
        echo "❌ Failed to clone repository. Check your URL or PAT."
        exit 1
    }
    cd "$REPO_NAME"
fi

echo "✅ Repository ready in $(pwd)"


echo "=========================================="
echo "🔐 Testing SSH connectivity to remote server..."
echo "=========================================="

if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo SSH connection successful"; then
    echo "✅ SSH connection established successfully."
else
    echo "❌ SSH connection failed. Please check your SSH details or key path."
    exit 1
fi

echo "=========================================="
echo "🛠 Preparing remote environment..."
echo "=========================================="

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
set -e

echo "Updating system packages..."
sudo apt update -y && sudo apt upgrade -y

echo "Installing Docker, Docker Compose, and Nginx..."
sudo apt install -y docker.io docker-compose nginx

echo "Enabling and starting Docker and Nginx..."
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx

echo "✅ Remote environment setup complete."
EOF

echo "=========================================="
echo "📂 Transferring project files to remote server..."
echo "=========================================="

scp -i "$SSH_KEY" -r . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app"

echo "✅ Files transferred successfully."

echo "=========================================="
echo "🐳 Deploying Dockerized application..."
echo "=========================================="

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
cd ~/app

if [ -f docker-compose.yml ]; then
    echo "Running docker-compose..."
    sudo docker-compose down
    sudo docker-compose up -d --build
else
    echo "No docker-compose.yml found. Looking for Dockerfile..."
    if [ -f Dockerfile ]; then
        sudo docker build -t myapp .
        sudo docker run -d -p $APP_PORT:$APP_PORT myapp
    else
        echo "❌ No Dockerfile or docker-compose.yml found."
        exit 1
    fi
fi

echo "✅ Docker container(s) running successfully."
EOF

echo "=========================================="
echo "🌐 Configuring Nginx as reverse proxy..."
echo "=========================================="

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
sudo bash -c 'cat > /etc/nginx/sites-available/myapp <<EOL
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOL'

sudo ln -sf /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

echo "✅ Nginx configured successfully."
EOF

echo "=========================================="
echo "🔍 Validating deployment..."
echo "=========================================="

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<'EOF'
set -e
echo "➡ Checking Docker service..."
sudo systemctl is-active --quiet docker && echo "✅ Docker is running." || echo "❌ Docker not running."

echo "➡ Checking running containers..."
sudo docker ps

echo "➡ Testing web server response..."
if curl -s --head http://localhost | grep "200 OK" > /dev/null; then
  echo "✅ Application is responding correctly."
else
  echo "⚠️ Application did not respond as expected."
fi
EOF

echo "✅ Deployment complete! Visit http://$SERVER_IP in your browser."
