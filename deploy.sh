#!/bin/bash

# === DevOps Stage 1: Automated Deployment Script ===
# Author: Moses
# Date: $(date)
# Description: Automates Dockerized app deployment to remote Linux server

# === Logging Setup ===
log_file="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$log_file") 2>&1
trap 'echo "❌ Error at line $LINENO"; exit 99' ERR

# === 1. Collect Parameters ===
echo "🚀 Starting Deployment..."

read -p "🔗 Git Repository URL: " repo_url
read -s -p "🔐 Personal Access Token (PAT): " pat; echo
read -p "🌿 Branch name [default: main]: " branch
branch=${branch:-main}
read -p "👤 SSH Username: " ssh_user
read -p "🌐 Server IP Address: " server_ip
read -p "🔑 SSH Key Path: " ssh_key
read -p "📦 Application Port (internal container port): " app_port

# === 2. Clone or Pull Repo ===
repo_name=$(basename "$repo_url" .git)
if [ -d "$repo_name" ]; then
  echo "📁 Repo exists. Pulling latest changes..."
  cd "$repo_name" && git pull origin "$branch"
else
  echo "📥 Cloning repo..."
  echo "📡 Cloning from: https://$pat@$(echo $repo_url | sed 's|https://||')"
  git clone "https://$pat@$(echo $repo_url | sed 's|https://||')"
  cd "$repo_name"
fi
git checkout "$branch"

# === 3. Validate Docker Setup ===
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  echo "✅ Docker configuration found."
else
  echo "❌ No Dockerfile or docker-compose.yml found." && exit 1
fi

# === 4. SSH Connection Test ===
echo "🔌 Testing SSH connection..."
ssh -i "$ssh_key" "$ssh_user@$server_ip" "echo '✅ SSH connection successful'" || exit 2

# === 5. Prepare Remote Environment ===
echo "🛠️ Preparing remote server..."
ssh -i "$ssh_key" "$ssh_user@$server_ip" << EOF
  sudo apt update
  sudo apt install -y docker.io docker-compose nginx
  sudo usermod -aG docker \$USER
  sudo systemctl enable docker nginx
  sudo systemctl start docker nginx
  docker --version && docker-compose --version && nginx -v
EOF

# === 6. Deploy Dockerized App ===
echo "📤 Transferring project files..."
rsync -avz -e "ssh -i $ssh_key" . "$ssh_user@$server_ip:/home/$ssh_user/$repo_name"

echo "🐳 Running containers..."
ssh -i "$ssh_key" "$ssh_user@$server_ip" << EOF
  cd /home/$ssh_user/$repo_name
  if [ -f "docker-compose.yml" ]; then
    docker-compose down
    docker-compose up -d
  else
    docker stop app || true && docker rm app || true
    docker build -t app .
    docker run -d --name app -p $app_port:$app_port app
  fi
EOF

# === 7. Configure Nginx Reverse Proxy ===
echo "🌐 Configuring Nginx..."
nginx_conf="/etc/nginx/sites-available/$repo_name"
ssh -i "$ssh_key" "$ssh_user@$server_ip" << EOF
  sudo bash -c 'cat > $nginx_conf <<EOL
server {
  listen 80;
  location / {
    proxy_pass http://localhost:$app_port;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOL'
  sudo ln -sf $nginx_conf /etc/nginx/sites-enabled/
  sudo nginx -t && sudo systemctl reload nginx
EOF

# === 8. Validate Deployment ===
echo "🔍 Validating deployment..."
ssh -i "$ssh_key" "$ssh_user@$server_ip" << EOF
  docker ps
  curl -I http://localhost
EOF
curl -I "http://$server_ip"

# === 9. Cleanup Option ===
if [ "$1" == "--cleanup" ]; then
  echo "🧹 Cleaning up deployment..."
  ssh -i "$ssh_key" "$ssh_user@$server_ip" << EOF
    docker-compose down || docker stop app && docker rm app
    sudo rm /etc/nginx/sites-available/$repo_name
    sudo rm /etc/nginx/sites-enabled/$repo_name
    sudo systemctl reload nginx
EOF
  echo "✅ Cleanup complete."
  exit 0
fi

# === 10. Done ===
echo "🎉 Deployment complete. Log saved to $log_file"
exit 0
