#!/bin/bash
set -e

SCRIPT_VERSION="1.0.0"
ENV_FILE=".env"
APP_DIR="/root/oplano"
DOCKER_COMPOSE_TEMPLATE_PATH="/root/instalador/docker-compose.yml"
CONFIG_TEMPLATE_DIR="/root/instalador/config"

COLOR_RESET=$(tput sgr0)
COLOR_RED=$(tput setaf 1)
COLOR_GREEN=$(tput setaf 2)
COLOR_YELLOW=$(tput setaf 3)
COLOR_BLUE=$(tput setaf 4)
COLOR_CYAN=$(tput setaf 6)

echo_info() { echo -e "${COLOR_BLUE}ℹ️  INFO:${COLOR_RESET} $1"; }
echo_success() { echo -e "${COLOR_GREEN}✅ SUCESSO:${COLOR_RESET} $1"; }
echo_warning() { echo -e "${COLOR_YELLOW}⚠️  AVISO:${COLOR_RESET} $1"; }
echo_error() {
  echo -e "${COLOR_RED}❌ ERRO:${COLOR_RESET} $1"
  exit 1
}
press_enter_to_continue() { read -r -p "Pressione Enter para continuar..."; }

check_interactive_terminal() {
  if ! [ -t 0 ]; then
    echo_error "Este terminal não suporta entrada interativa. Execute via SSH ou terminal com suporte à digitação."
  fi
}

generate_secure_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"
}

generate_long_secure_string() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"
}

check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo_warning "Comando '$1' não encontrado."
    return 1
  fi
  return 0
}

install_docker() {
  if ! check_command "docker"; then
    echo_info "Instalando Docker..."
    local codename
    if command -v lsb_release >/dev/null 2>&1; then
      codename=$(lsb_release -cs)
    else
      codename="noble"
    fi

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg

    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    if ! grep -q "download.docker.com" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
      echo_info "Adicionando repositório oficial do Docker..."
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    fi

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER" || echo_warning "Falha ao adicionar usuário ao grupo docker."
    echo_success "Docker instalado."
    echo_info "Por favor, faça logout e login novamente ou execute 'newgrp docker'."
  fi
}

install_docker_compose() {
  if ! docker compose version &>/dev/null; then
    echo_info "Docker Compose (plugin) não encontrado. Tentando instalar..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
    if ! docker compose version &>/dev/null; then
      echo_error "Falha ao instalar Docker Compose."
    fi
    echo_success "Docker Compose instalado."
  fi
}

install_nodejs() {
  if ! check_command "node"; then
    echo_info "Instalando Node.js (v20.x)..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo_success "Node.js instalado."
  fi
}

optimize_system_performance() {
  echo_info "Aplicando otimizações de performance do sistema..."
  local needs_limits_update=false
  local needs_sysctl_update=false

  if ! grep -q "# OnTicket optimizations" /etc/security/limits.conf 2>/dev/null; then
    needs_limits_update=true
  fi

  if ! grep -q "# OnTicket optimizations" /etc/sysctl.conf 2>/dev/null; then
    needs_sysctl_update=true
  fi

  if [ "$needs_limits_update" = true ]; then
    [ -f /etc/security/limits.conf ] && sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak.$(date +%Y%m%d-%H%M%S)
  fi

  if [ "$needs_sysctl_update" = true ]; then
    [ -f /etc/sysctl.conf ] && sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d-%H%M%S)
  fi

  echo_info "Configurando limites do sistema (ulimits)..."
  if [ "$needs_limits_update" = true ]; then
    sudo tee -a /etc/security/limits.conf >/dev/null <<'EOF'

# OnTicket optimizations
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
EOF
    echo_success "Limites do sistema configurados."
  fi

  echo_info "Configurando parâmetros do kernel..."
  if [ "$needs_sysctl_update" = true ]; then
    sudo tee -a /etc/sysctl.conf >/dev/null <<'EOF'

# OnTicket optimizations

# Network performance
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# File descriptors
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Memory
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    echo_success "Parâmetros do kernel configurados."
    echo_info "Aplicando configurações do kernel..."
    sudo sysctl -p >/dev/null 2>&1
    echo_success "Configurações do kernel aplicadas."
  fi
}

optimize_docker_daemon() {
  echo_info "Aplicando otimizações do Docker daemon..."
  local docker_daemon_file="/etc/docker/daemon.json"
  local needs_docker_update=false

  sudo mkdir -p /etc/docker

  if [ -f "$docker_daemon_file" ]; then
    if grep -q '"log-driver"' "$docker_daemon_file" 2>/dev/null && \
       grep -q '"default-ulimits"' "$docker_daemon_file" 2>/dev/null; then
      needs_docker_update=false
    else
      needs_docker_update=true
    fi
  else
    needs_docker_update=true
  fi

  if [ "$needs_docker_update" = true ] && [ -f "$docker_daemon_file" ]; then
    sudo cp "$docker_daemon_file" "${docker_daemon_file}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  if [ "$needs_docker_update" = true ]; then
    sudo tee "$docker_daemon_file" >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EOF
    echo_success "Arquivo daemon.json configurado."
    echo_info "Reiniciando Docker daemon..."
    if sudo systemctl restart docker; then
      echo_success "Docker daemon reiniciado com sucesso."
      sleep 3
    else
      echo_warning "Falha ao reiniciar Docker."
    fi
  fi
}

check_and_install_dependencies() {
  echo_info "Verificando dependências..."
  install_docker
  install_docker_compose
  install_nodejs
  echo ""
  echo_info "Aplicando otimizações de performance..."
  optimize_system_performance
  optimize_docker_daemon
  echo_success "Todas as dependências necessárias estão presentes ou foram instaladas."
}

get_environment_tag() {
  echo_info "Selecione o ambiente para as imagens Docker:"
  options=("Produção (tag: latest)" "Desenvolvimento (tag: develop)")
  select opt in "${options[@]}"; do
    case $opt in
    "Produção (tag: latest)")
      DOCKER_TAG="latest"
      NODE_ENV="production"
      break
      ;;
    "Desenvolvimento (tag: develop)")
      DOCKER_TAG="develop"
      NODE_ENV="development"
      break
      ;;
    *) echo_warning "Opção inválida." ;;
    esac
  done
  echo_info "Ambiente selecionado: $DOCKER_TAG"
}

collect_ghcr_image_details() {
  echo_info "Configuração das Imagens Docker do GHCR:"
  prompt_for_variable "GHCR_IMAGE_USER" "  Usuário/Organização do GitHub" "${GHCR_IMAGE_USER_CURRENT}" "oplanov2-entrega" "oplanov2-entrega"
  prompt_for_variable "GHCR_IMAGE_REPO" "  Nome do Repositório no GitHub" "${GHCR_IMAGE_REPO_CURRENT}" "entrega-oplanov2" "entrega-oplanov2"
}

collect_traefik_email() {
  echo_info "Configuração do Traefik:"
  prompt_for_variable "EMAIL" "  E-mail para SSL" "${EMAIL_CURRENT}" "" "seu@email.com" validate_email
}

validate_domain() {
  local domain="$1"
  if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 1
  fi
  return 0
}

validate_port() {
  local port="$1"
  if [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
    return 0
  fi
  return 1
}

validate_email() {
  local email="$1"
  if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  fi
  return 1
}

prompt_for_variable() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="$3"
  local default_value="$4"
  local example="$5"
  local validator="$6"
  local new_value
  while true; do
    if [ -n "$current_value" ]; then
      read -r -p "$prompt_text [$current_value]${example:+ | Ex: $example}: " new_value
      new_value="${new_value:-$current_value}"
    elif [ -n "$default_value" ]; then
      read -r -p "$prompt_text (Padrão: $default_value)${example:+ | Ex: $example}: " new_value
      new_value="${new_value:-$default_value}"
    else
      read -r -p "$prompt_text${example:+ | Ex: $example}: " new_value
    fi
    if [ -z "$validator" ] || [ -z "$new_value" ] || $validator "$new_value"; then
      eval "$var_name=\"$new_value\""
      break
    else
      echo_warning "Valor inválido. Tente novamente."
    fi
  done
}

collect_domains() {
  echo_info "Configuração de Domínios:"
  prompt_for_variable "FRONTEND_DOMAIN" "  URL do FRONTEND" "${FRONTEND_DOMAIN_CURRENT}" "" "app.seudominio.com" validate_domain
  prompt_for_variable "BACKEND_DOMAIN" "  URL do BACKEND" "${BACKEND_DOMAIN_CURRENT}" "" "api.seudominio.com" validate_domain
}

collect_facebook_credentials() {
  echo_info "Configuração do Facebook e Instagram (Opcional):"
  prompt_for_variable "FACEBOOK_APP_ID" "  FACEBOOK_APP_ID" "${FACEBOOK_APP_ID_CURRENT}"
  prompt_for_variable "FACEBOOK_APP_SECRET" "  FACEBOOK_APP_SECRET" "${FACEBOOK_APP_SECRET_CURRENT}"
  prompt_for_variable "VERIFY_TOKEN" "  VERIFY_TOKEN" "${VERIFY_TOKEN_CURRENT:-$(generate_secure_password 16)}"
  prompt_for_variable "REQUIRE_BUSINESS_MANAGEMENT" "  REQUIRE_BUSINESS_MANAGEMENT (true/false)" "${REQUIRE_BUSINESS_MANAGEMENT_CURRENT:-true}"
}

collect_gerencianet_credentials() {
  echo_info "Configuração da Gerencianet:"
  local setup_gerencianet_prompt="Deseja configurar a integração com Gerencianet agora? (s/N)"
  local current_choice="N"

  if [ -n "$GERENCIANET_CLIENT_ID_CURRENT" ] || [ -n "$GERENCIANET_CLIENT_SECRET_CURRENT" ]; then
    current_choice="s"
  fi

  read -r -p "$setup_gerencianet_prompt (Padrão: $current_choice): " choice
  SETUP_GERENCIANET="${choice:-$current_choice}"

  if [[ "$SETUP_GERENCIANET" == "s" || "$SETUP_GERENCIANET" == "S" ]]; then
    prompt_for_variable "GERENCIANET_SANDBOX" "  GERENCIANET_SANDBOX (true/false)" "${GERENCIANET_SANDBOX_CURRENT:-true}"
    prompt_for_variable "GERENCIANET_CLIENT_ID" "  GERENCIANET_CLIENT_ID" "${GERENCIANET_CLIENT_ID_CURRENT}"
    prompt_for_variable "GERENCIANET_CLIENT_SECRET" "  GERENCIANET_CLIENT_SECRET" "${GERENCIANET_CLIENT_SECRET_CURRENT}"
    prompt_for_variable "GERENCIANET_CHAVEPIX" "  CHAVE PIX" "${GERENCIANET_CHAVEPIX_CURRENT}"
    prompt_for_variable "GERENCIANET_PIX_CERT" "  Caminho do certificado PIX (.p12)" "${GERENCIANET_PIX_CERT_CURRENT}"
  else
    GERENCIANET_SANDBOX=""
    GERENCIANET_CLIENT_ID=""
    GERENCIANET_CLIENT_SECRET=""
    GERENCIANET_CHAVEPIX=""
    GERENCIANET_PIX_CERT=""
  fi
}

collect_other_configs() {
  echo_info "Outras Configurações:"
  prompt_for_variable "MASTER_KEY" "  MASTER_KEY" "${MASTER_KEY_CURRENT}"
  if [ -z "$MASTER_KEY" ]; then
    read -r -p "Pressione Enter para gerar uma MASTER_KEY automaticamente ou digite uma: " user_master_key_input
    if [ -z "$user_master_key_input" ]; then
      MASTER_KEY=$(generate_long_secure_string 16)
      echo_info "MASTER_KEY gerada: $MASTER_KEY"
    else
      MASTER_KEY=$user_master_key_input
    fi
  fi
  prompt_for_variable "NUMBER_SUPPORT" "  Número de Suporte" "${NUMBER_SUPPORT_CURRENT}"
}

set_credentials_mode() {
  echo_info "Como deseja definir as credenciais?"
  options=("Gerar automaticamente" "Digitar manualmente")
  select opt in "${options[@]}"; do
    case $opt in
    "Gerar automaticamente")
      CREDENTIAL_MODE="auto"
      break
      ;;
    "Digitar manualmente")
      CREDENTIAL_MODE="manual"
      break
      ;;
    *) echo_warning "Opção inválida." ;;
    esac
  done
}

set_database_credentials() {
  echo_info "Configurando Banco de Dados:"
  if [ "$CREDENTIAL_MODE" == "auto" ]; then
    DB_NAME="oplano_$(generate_secure_password 8)"
    DB_USER="oplano_$(generate_secure_password 8)"
    DB_PASS="$(generate_secure_password 24)"
  else
    prompt_for_variable "DB_NAME" "  Nome do Banco" "${DB_NAME_CURRENT:-oplano}"
    prompt_for_variable "DB_USER" "  Usuário do Banco" "${DB_USER_CURRENT:-oplano}"
    prompt_for_variable "DB_PASS" "  Senha do Banco"
  fi
}

set_rabbitmq_credentials() {
  echo_info "Configurando RabbitMQ:"
  if [ "$CREDENTIAL_MODE" == "auto" ]; then
    RABBIT_USER="rabbit_$(generate_secure_password 8)"
    RABBIT_PASS="$(generate_secure_password 24)"
  else
    prompt_for_variable "RABBIT_USER" "  Usuário do RabbitMQ" "${RABBIT_USER_CURRENT:-oplano}"
    prompt_for_variable "RABBIT_PASS" "  Senha do RabbitMQ"
  fi
}

set_redis_credentials() {
  echo_info "Configurando Redis:"
  if [ "$CREDENTIAL_MODE" == "auto" ]; then
    REDIS_PASSWORD="$(generate_secure_password 24)"
  else
    while true; do
      prompt_for_variable "REDIS_PASSWORD" "  Senha do Redis" "${REDIS_PASSWORD_CURRENT}"
      if [ -n "$REDIS_PASSWORD" ]; then
        break
      fi
    done
  fi
}

generate_internal_secrets() {
  echo_info "Gerando chaves internas..."
  JWT_SECRET="${JWT_SECRET_CURRENT:-$(openssl rand -base64 44)}"
  JWT_REFRESH_SECRET="${JWT_REFRESH_SECRET_CURRENT:-$(openssl rand -base64 44)}"
  COMPANY_TOKEN="${COMPANY_TOKEN_CURRENT:-$(generate_long_secure_string 16)}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-${REDIS_PASSWORD_CURRENT:-$(generate_secure_password 24)}}"
}

load_env_file() {
  if [ -f "$APP_DIR/$ENV_FILE" ]; then
    echo_info "Carregando configurações..."
    set -o allexport
    # shellcheck source=/dev/null
    source "$APP_DIR/$ENV_FILE"
    set +o allexport

    FRONTEND_DOMAIN_CURRENT="$FRONTEND_DOMAIN"
    BACKEND_DOMAIN_CURRENT="$BACKEND_DOMAIN"
    EMAIL_CURRENT="$EMAIL"
    FACEBOOK_APP_ID_CURRENT="$FACEBOOK_APP_ID"
    FACEBOOK_APP_SECRET_CURRENT="$FACEBOOK_APP_SECRET"
    VERIFY_TOKEN_CURRENT="$VERIFY_TOKEN"
    GERENCIANET_SANDBOX_CURRENT="$GERENCIANET_SANDBOX"
    GERENCIANET_CLIENT_ID_CURRENT="$GERENCIANET_CLIENT_ID"
    GERENCIANET_CLIENT_SECRET_CURRENT="$GERENCIANET_CLIENT_SECRET"
    GERENCIANET_CHAVEPIX_CURRENT="$GERENCIANET_CHAVEPIX"
    GERENCIANET_PIX_CERT_CURRENT="$GERENCIANET_PIX_CERT"
    DB_NAME_CURRENT="$DB_NAME"
    DB_USER_CURRENT="$DB_USER"
    DB_PASS_CURRENT="$DB_PASS"
    RABBIT_USER_CURRENT="$RABBIT_USER"
    RABBIT_PASS_CURRENT="$RABBIT_PASS"
    REDIS_PASSWORD_CURRENT="$REDIS_PASSWORD"
    DOCKER_TAG_CURRENT="$DOCKER_TAG"
    GHCR_IMAGE_USER_CURRENT="$GHCR_IMAGE_USER"
    GHCR_IMAGE_REPO_CURRENT="$GHCR_IMAGE_REPO"
    NODE_ENV_CURRENT="$NODE_ENV"
    JWT_SECRET_CURRENT="$JWT_SECRET"
    JWT_REFRESH_SECRET_CURRENT="$JWT_REFRESH_SECRET"
    COMPANY_TOKEN_CURRENT="$COMPANY_TOKEN"
    MASTER_KEY_CURRENT="$MASTER_KEY"
    NUMBER_SUPPORT_CURRENT="$NUMBER_SUPPORT"
    REQUIRE_BUSINESS_MANAGEMENT_CURRENT="$REQUIRE_BUSINESS_MANAGEMENT"

    return 0
  else
    return 1
  fi
}

save_env_file() {
  echo_info "Salvando configurações..."
  mkdir -p "$APP_DIR"

  cat >"$APP_DIR/$ENV_FILE" <<EOF
NODE_ENV=${NODE_ENV:-production}
DOCKER_TAG=${DOCKER_TAG:-latest}
EMAIL=${EMAIL:-seu@email.com}

GHCR_IMAGE_USER=${GHCR_IMAGE_USER:-oplanov2-entrega}
GHCR_IMAGE_REPO=${GHCR_IMAGE_REPO:-entrega-oplanov2}

FRONTEND_DOMAIN=${FRONTEND_DOMAIN}
BACKEND_DOMAIN=${BACKEND_DOMAIN}
FRONTEND_URL=https://${FRONTEND_DOMAIN}
BACKEND_URL=https://${BACKEND_DOMAIN}

DB_DIALECT=postgres
DB_HOST=whaticket-pgbouncer
DB_PORT=6432
DB_HOST_DIRECT=whaticket-postgres
DB_PORT_DIRECT=5432
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

RABBITMQ_HOST=whaticket-rabbitmq
RABBITMQ_PORT=5672
RABBIT_USER=${RABBIT_USER}
RABBIT_PASS=${RABBIT_PASS}
RABBITMQ_URI=amqp://\${RABBIT_USER}:\${RABBIT_PASS}@whaticket-rabbitmq:5672/

REDIS_HOST=whaticket-redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URI=redis://:\${REDIS_PASSWORD}@whaticket-redis:6379

JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
VERIFY_TOKEN=${VERIFY_TOKEN}
ENV_TOKEN=OPLANOV2
COMPANY_TOKEN=${COMPANY_TOKEN}
MASTER_KEY=${MASTER_KEY}

FACEBOOK_APP_ID=${FACEBOOK_APP_ID}
FACEBOOK_APP_SECRET=${FACEBOOK_APP_SECRET}
REQUIRE_BUSINESS_MANAGEMENT=${REQUIRE_BUSINESS_MANAGEMENT}

GERENCIANET_SANDBOX=${GERENCIANET_SANDBOX}
GERENCIANET_CLIENT_ID=${GERENCIANET_CLIENT_ID}
GERENCIANET_CLIENT_SECRET=${GERENCIANET_CLIENT_SECRET}
GERENCIANET_CHAVEPIX=${GERENCIANET_CHAVEPIX}
GERENCIANET_PIX_CERT=${GERENCIANET_PIX_CERT}

PROXY_PORT=443
TIMEOUT_TO_IMPORT_MESSAGE=100
NUMBER_SUPPORT=${NUMBER_SUPPORT}
EOF
}

docker_login() {
  if grep -q '"ghcr.io"' ~/.docker/config.json 2>/dev/null; then
    return 0
  fi

  local ghcr_user_login
  local ghcr_token
  echo_info "Login no GHCR"
  while true; do
    read -r -p "  Usuário GitHub: " ghcr_user_login
    read -s -r -p "  Token (PAT): " ghcr_token
    echo
    if [ -n "$ghcr_user_login" ] && [ -n "$ghcr_token" ]; then
      break
    else
      echo_warning "Tente novamente."
    fi
  done

  if echo "$ghcr_token" | docker login ghcr.io -u "$ghcr_user_login" --password-stdin; then
    echo_success "Login realizado."
  else
    echo_error "Falha no login."
  fi
}

adjust_docker_compose_images() {
  local target_compose_file="$APP_DIR/docker-compose.yml"
  if [ ! -f "$target_compose_file" ]; then
    echo_error "docker-compose.yml não encontrado."
    return 1
  fi

  echo_info "Ajustando imagens..."

  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    if [ -z "$GHCR_IMAGE_USER" ] || [ -z "$GHCR_IMAGE_REPO" ]; then
      echo_error "Dados do GHCR incompletos."
      return 1
    fi
    sed -i.bak \
      -e "s|ghcr.io/seu-usuario/seu-repositorio/backend|ghcr.io/${GHCR_IMAGE_USER}/${GHCR_IMAGE_REPO}/backend|g" \
      -e "s|ghcr.io/seu-usuario/seu-repositorio/frontend|ghcr.io/${GHCR_IMAGE_USER}/${GHCR_IMAGE_REPO}/frontend|g" \
      "$target_compose_file"
  elif [ "$OPERATION_TYPE" == "local_build" ]; then
    sed -i.bak \
      -e "s|image: ghcr.io/seu-usuario/seu-repositorio/backend:\${DOCKER_TAG}|image: oplano/backend:${DOCKER_TAG}|g" \
      -e "s|image: ghcr.io/seu-usuario/seu-repositorio/frontend:\${DOCKER_TAG}|image: oplano/frontend:${DOCKER_TAG}|g" \
      "$target_compose_file"
  fi
  rm -f "${target_compose_file}.bak"
}

copy_docker_compose_template_and_adjust() {
  echo_info "Copiando template..."
  if [ ! -f "$DOCKER_COMPOSE_TEMPLATE_PATH" ]; then
    echo_error "Template não encontrado."
  fi
  mkdir -p "$APP_DIR"
  cp -f "$DOCKER_COMPOSE_TEMPLATE_PATH" "$APP_DIR/docker-compose.yml"
  adjust_docker_compose_images
}

sync_config_templates() {
  echo_info "Sincronizando configs..."
  if [ ! -d "$CONFIG_TEMPLATE_DIR" ]; then
    return
  fi
  local config_dir="$APP_DIR/config"
  mkdir -p "$config_dir"
  local files=()
  for rel_path in "${files[@]}"; do
    local source_file="$CONFIG_TEMPLATE_DIR/$rel_path"
    local target_file="$config_dir/$rel_path"
    local target_parent
    target_parent=$(dirname "$target_file")
    if [ ! -f "$source_file" ]; then
      continue
    fi
    mkdir -p "$target_parent"
    cp -f "$source_file" "$target_file"
  done
}

generate_pgbouncer_config() {
  echo_info "Gerando configs PgBouncer..."
  local pgbouncer_dir="$APP_DIR/config/pgbouncer"
  mkdir -p "$pgbouncer_dir"

  cat >"$pgbouncer_dir/pgbouncer.ini" <<'PGBOUNCER_INI'
[databases]
* = host=whaticket-postgres port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 10
reserve_pool_timeout = 5.0
max_client_conn = 400
max_db_connections = 100
server_reset_query = DISCARD ALL
server_lifetime = 3600
server_idle_timeout = 600
client_login_timeout = 60
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
admin_users = ${DB_USER}
stats_users = ${DB_USER}
PGBOUNCER_INI

  sed -i "s/\${DB_USER}/${DB_USER}/g" "$pgbouncer_dir/pgbouncer.ini"
  cat >"$pgbouncer_dir/userlist.txt" <<EOF
"${DB_USER}" "${DB_PASS}"
EOF
}

docker_compose_pull() {
  echo_info "Atualizando imagens..."
  cd "$APP_DIR" || echo_error "Falha ao acessar diretório."
  if docker compose pull; then
    echo_success "Imagens atualizadas."
  else
    echo_error "Falha ao baixar imagens."
  fi
}

docker_compose_up() {
  echo_info "Iniciando serviços..."
  cd "$APP_DIR" || echo_error "Falha ao acessar diretório."
  set -o allexport
  source "$APP_DIR/$ENV_FILE"
  set +o allexport

  if docker compose up -d --remove-orphans; then
    echo_success "Serviços iniciados."
  else
    echo_error "Falha ao iniciar serviços."
  fi
}

show_summary_and_confirm() {
  echo "${COLOR_CYAN}====== Resumo ======${COLOR_RESET}"
  echo "  E-mail:       ${EMAIL}"
  echo "  Frontend:     https://${FRONTEND_DOMAIN}"
  echo "  Backend:      https://${BACKEND_DOMAIN}"
  echo "  Ambiente:     ${NODE_ENV}"
  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    echo "  Tag:          ${DOCKER_TAG}"
  fi
  echo "  DB Name:      ${DB_NAME}"
  echo "  DB User:      ${DB_USER}"
  echo "${COLOR_CYAN}====================${COLOR_RESET}"
  read -r -p "Confirmar? (s/N): " confirmation
  if [[ "$confirmation" != "s" && "$confirmation" != "S" ]]; then
    echo_error "Cancelado."
  fi
}

collect_all_data_new_install() {
  collect_traefik_email
  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    get_environment_tag
    collect_ghcr_image_details
  else
    prompt_for_variable "NODE_ENV" "  Ambiente" "${NODE_ENV_CURRENT:-production}" "production"
    DOCKER_TAG="local"
  fi
  collect_domains
  collect_facebook_credentials
  collect_gerencianet_credentials
  collect_other_configs
  set_credentials_mode
  set_database_credentials
  set_rabbitmq_credentials
  set_redis_credentials
  generate_internal_secrets
}

collect_data_update_simplified() {
  if ! load_env_file; then
    read -r -p "Configuração não encontrada. Nova instalação? (s/N): " choice
    if [[ "$choice" == "s" || "$choice" == "S" ]]; then
      if [ "$OPERATION_TYPE" == "ghcr" ]; then
        run_new_ghcr_installation
      else
        run_new_local_build_installation
      fi
      exit 0
    else
      echo_error "Cancelado."
    fi
  fi

  echo_info "Atualização Simplificada"

  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    get_environment_tag
    prompt_for_variable "GHCR_IMAGE_USER" "  Usuário GitHub" "${GHCR_IMAGE_USER_CURRENT}" "oplanov2-entrega"
    prompt_for_variable "GHCR_IMAGE_REPO" "  Repositório GitHub" "${GHCR_IMAGE_REPO_CURRENT}" "entrega-oplanov2"
  else
    prompt_for_variable "NODE_ENV" "  Ambiente" "${NODE_ENV_CURRENT:-production}"
    DOCKER_TAG="local"
  fi

  read -r -p "Alterar outras configurações? (s/N): " change_other_configs

  if [[ "$change_other_configs" == "s" || "$change_other_configs" == "S" ]]; then
    collect_traefik_email
    collect_domains
    collect_facebook_credentials
    collect_gerencianet_credentials
    collect_other_configs

    DB_NAME="$DB_NAME_CURRENT"
    DB_USER="$DB_USER_CURRENT"
    prompt_for_variable "DB_PASS" "  Senha DB"
    DB_PASS=${DB_PASS:-$DB_PASS_CURRENT}

    RABBIT_USER="$RABBIT_USER_CURRENT"
    prompt_for_variable "RABBIT_PASS" "  Senha RabbitMQ"
    RABBIT_PASS=${RABBIT_PASS:-$RABBIT_PASS_CURRENT}

    prompt_for_variable "REDIS_PASSWORD" "  Senha Redis" "${REDIS_PASSWORD_CURRENT}"
    REDIS_PASSWORD=${REDIS_PASSWORD:-$REDIS_PASSWORD_CURRENT}
  else
    EMAIL="$EMAIL_CURRENT"
    FRONTEND_DOMAIN="$FRONTEND_DOMAIN_CURRENT"
    BACKEND_DOMAIN="$BACKEND_DOMAIN_CURRENT"
    FACEBOOK_APP_ID="$FACEBOOK_APP_ID_CURRENT"
    FACEBOOK_APP_SECRET="$FACEBOOK_APP_SECRET_CURRENT"
    VERIFY_TOKEN="$VERIFY_TOKEN_CURRENT"
    REQUIRE_BUSINESS_MANAGEMENT="$REQUIRE_BUSINESS_MANAGEMENT_CURRENT"
    GERENCIANET_SANDBOX="$GERENCIANET_SANDBOX_CURRENT"
    GERENCIANET_CLIENT_ID="$GERENCIANET_CLIENT_ID_CURRENT"
    GERENCIANET_CLIENT_SECRET="$GERENCIANET_CLIENT_SECRET_CURRENT"
    GERENCIANET_CHAVEPIX="$GERENCIANET_CHAVEPIX_CURRENT"
    GERENCIANET_PIX_CERT="$GERENCIANET_PIX_CERT_CURRENT"
    MASTER_KEY="$MASTER_KEY_CURRENT"
    NUMBER_SUPPORT="$NUMBER_SUPPORT_CURRENT"
    DB_NAME="$DB_NAME_CURRENT"
    DB_USER="$DB_USER_CURRENT"
    DB_PASS="$DB_PASS_CURRENT"
    RABBIT_USER="$RABBIT_USER_CURRENT"
    RABBIT_PASS="$RABBIT_PASS_CURRENT"
    REDIS_PASSWORD="$REDIS_PASSWORD_CURRENT"
  fi
  generate_internal_secrets
}

run_new_ghcr_installation() {
  OPERATION_TYPE="ghcr"
  echo_info "Nova Instalação (GHCR)..."
  collect_all_data_new_install
  show_summary_and_confirm
  save_env_file
  copy_docker_compose_template_and_adjust
  sync_config_templates
  generate_pgbouncer_config
  docker_login
  docker_compose_pull
  docker_compose_up
  echo_success "Concluído!"
  show_post_install_info
}

run_update_ghcr_installation() {
  OPERATION_TYPE="ghcr"
  echo_info "Atualização (GHCR)..."
  collect_data_update_simplified
  show_summary_and_confirm
  save_env_file
  copy_docker_compose_template_and_adjust
  sync_config_templates
  generate_pgbouncer_config
  docker_login
  docker_compose_pull
  docker_compose_up
  echo_success "Concluído!"
  show_post_install_info
}

setup_local_repo() {
  prompt_for_variable "REPO_URL" "  URL Git" "${REPO_URL_CURRENT}"
  prompt_for_variable "REPO_BRANCH" "  Branch" "${REPO_BRANCH_CURRENT:-main}"
  read -r -p "  Token privado necessário? (s/N): " private_repo_choice
  if [[ "$private_repo_choice" == "s" || "$private_repo_choice" == "S" ]]; then
    prompt_for_variable "REPO_TOKEN" "  Token (PAT)"
  else
    REPO_TOKEN=""
  fi

  REPO_URL_CURRENT="$REPO_URL"
  REPO_BRANCH_CURRENT="$REPO_BRANCH"
  local repo_source_dir="$APP_DIR/source_code"
  mkdir -p "$repo_source_dir"

  if [ ! -d "$repo_source_dir/.git" ]; then
    echo_info "Clonando..."
    local clone_url="$REPO_URL"
    if [ -n "$REPO_TOKEN" ]; then
      clone_url="https://${REPO_TOKEN}@${REPO_URL#https://}"
    fi
    if git clone --branch "$REPO_BRANCH" "$clone_url" "$repo_source_dir"; then
      echo_success "Clonado."
    else
      echo_error "Falha ao clonar."
    fi
  else
    echo_info "Atualizando Git..."
    cd "$repo_source_dir"
    git stash push -u
    if git checkout "$REPO_BRANCH" && git pull origin "$REPO_BRANCH"; then
      echo_success "Atualizado."
      git stash pop || true
    else
      git stash pop || true
      echo_error "Falha ao atualizar Git."
    fi
    cd "$APP_DIR"
  fi
}

build_local_images() {
  local repo_source_dir="$APP_DIR/source_code"
  if [ ! -d "$repo_source_dir" ]; then
    echo_error "Código fonte não encontrado."
  fi
  echo_info "Buildando imagens..."
  for svc in backend frontend; do
    local dockerfile_path="$repo_source_dir/$svc/Dockerfile"
    local context_path="$repo_source_dir/$svc"
    local image_name="oplano/${svc}:${DOCKER_TAG}"
    if [ -f "$dockerfile_path" ]; then
      echo_info "Buildando $image_name..."
      if docker build -t "$image_name" --build-arg NODE_ENV="$NODE_ENV" "$context_path"; then
        echo_success "Sucesso."
      else
        echo_error "Falha no build."
      fi
    else
      echo_warning "Dockerfile não encontrado para $svc."
    fi
  done
  copy_docker_compose_template_and_adjust
}

run_new_local_build_installation() {
  OPERATION_TYPE="local_build"
  echo_info "Nova Instalação (Local)..."
  setup_local_repo
  collect_all_data_new_install
  show_summary_and_confirm
  save_env_file
  build_local_images
  sync_config_templates
  generate_pgbouncer_config
  docker_compose_up
  echo_success "Concluído!"
  show_post_install_info
}

run_update_local_build_installation() {
  OPERATION_TYPE="local_build"
  echo_info "Atualização (Local)..."
  setup_local_repo
  collect_data_update_simplified
  show_summary_and_confirm
  save_env_file
  build_local_images
  sync_config_templates
  generate_pgbouncer_config
  docker_compose_up
  echo_success "Concluído!"
  show_post_install_info
}

run_reset_installation() {
  echo_warning "!!! ATENÇÃO: DESTRUTIVO E IRREVERSÍVEL !!!"
  read -r -p "Confirmar reset? (Digite 'SIM'): " confirmation
  if [ "$confirmation" != "SIM" ]; then
    echo_info "Cancelado."
    exit 0
  fi

  echo_info "Resetando..."
  if [ -f "$APP_DIR/docker-compose.yml" ]; then
    cd "$APP_DIR" || true
    docker compose down --volumes --remove-orphans || true
  fi

  docker system prune -af --volumes || true
  rm -f "$APP_DIR/$ENV_FILE"
  rm -rf "$APP_DIR/source_code"
  rm -f "$APP_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml.bak"
  rm -rf "$APP_DIR/config"
  cd "$INSTALLER_DIR" || true
  echo_success "Reset concluído."
}

show_post_install_info() {
  echo ""
  echo "${COLOR_CYAN}====== Sucesso ======${COLOR_RESET}"
  echo "  Frontend: https://${FRONTEND_DOMAIN}"
  echo "  Backend:  https://${BACKEND_DOMAIN}"
  echo "  Redis PW: ${REDIS_PASSWORD}"
  echo "  DB Name:  ${DB_NAME}"
  echo "  DB User:  ${DB_USER}"
  echo "${COLOR_CYAN}=====================${COLOR_RESET}"
}

main_menu_header() {
  clear
  echo "${COLOR_CYAN}=== Instalador OPLANO $SCRIPT_VERSION ===${COLOR_RESET}"
}

select_operation_mode() {
  main_menu_header
  echo "1) Nova Instalação (GHCR)"
  echo "2) Atualizar Instalação (GHCR)"
  echo "3) Nova Instalação (Build Local)"
  echo "4) Atualizar Instalação (Build Local)"
  echo "5) Resetar Instalação"
  echo "6) Sair"
  while true; do
    read -rp "Opção: " opt
    case $opt in
    1) OPERATION_MODE="new_ghcr"; break ;;
    2) OPERATION_MODE="update_ghcr"; break ;;
    3) OPERATION_MODE="new_local"; break ;;
    4) OPERATION_MODE="update_local"; break ;;
    5) OPERATION_MODE="reset"; break ;;
    6) exit 0 ;;
    *) echo_warning "Inválido." ;;
    esac
  done
}

check_interactive_terminal
check_and_install_dependencies

mkdir -p "$APP_DIR"
INSTALLER_DIR="$(pwd)"

if [ ! -f "$DOCKER_COMPOSE_TEMPLATE_PATH" ]; then
  if [ -f "./docker-compose.yml" ]; then
    DOCKER_COMPOSE_TEMPLATE_PATH="$(pwd)/docker-compose.yml"
  else
    echo_error "Template docker-compose.yml não encontrado."
  fi
fi

if [ ! -d "$CONFIG_TEMPLATE_DIR" ]; then
  if [ -d "$INSTALLER_DIR/config" ]; then
    CONFIG_TEMPLATE_DIR="$INSTALLER_DIR/config"
  fi
fi

select_operation_mode

case "$OPERATION_MODE" in
"new_ghcr") run_new_ghcr_installation ;;
"update_ghcr") run_update_ghcr_installation ;;
"new_local") run_new_local_build_installation ;;
"update_local") run_update_local_build_installation ;;
"reset") run_reset_installation ;;
*) echo_error "Erro." ;;
esac

exit 0
