#!/bin/bash
set -e

# --- Global ---
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

# --- Logs ---
echo_info() { echo -e "${COLOR_BLUE}ℹ️  INFO:${COLOR_RESET} $1"; }
echo_success() { echo -e "${COLOR_GREEN}✅ SUCESSO:${COLOR_RESET} $1"; }
echo_warning() { echo -e "${COLOR_YELLOW}⚠️  AVISO:${COLOR_RESET} $1"; }
echo_error() {
  echo -e "${COLOR_RED}❌ ERRO:${COLOR_RESET} $1"
  exit 1
}
press_enter_to_continue() { read -r -p "Pressione Enter para continuar..."; }

# Verifica terminal interativo
check_interactive_terminal() {
  if ! [ -t 0 ]; then
    echo_error "Este terminal não suporta entrada interativa (read). Execute este script via SSH ou terminal com suporte à digitação."
  fi
}

generate_secure_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"
}

generate_long_secure_string() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"
}

# --- Checagem de comandos ---
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
    curl -fsSL https://get.docker.com -o install-docker.sh
    sudo sh install-docker.sh --channel stable
    sudo usermod -aG docker "$USER" || echo_warning "Falha ao adicionar usuário ao grupo docker. Você pode precisar reiniciar sua sessão."
    rm install-docker.sh
    echo_success "Docker instalado."
    echo_info "Por favor, faça logout e login novamente ou reinicie o sistema para que as alterações no grupo docker tenham efeito, ou execute 'newgrp docker' no terminal atual."
  fi
}

install_docker_compose() {
  if ! docker compose version &>/dev/null; then
    echo_info "Docker Compose (plugin) não encontrado. Tentando instalar..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
    if ! docker compose version &>/dev/null; then
      echo_error "Falha ao instalar Docker Compose. Verifique a documentação do Docker para o seu sistema."
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
  
  # Verificar se precisa atualizar limits.conf
  if ! grep -q "# OnTicket optimizations" /etc/security/limits.conf 2>/dev/null; then
    needs_limits_update=true
  fi
  
  # Verificar se precisa atualizar sysctl.conf
  if ! grep -q "# OnTicket optimizations" /etc/sysctl.conf 2>/dev/null; then
    needs_sysctl_update=true
  fi
  
  # Backup dos arquivos apenas se for modificá-los
  if [ "$needs_limits_update" = true ]; then
    [ -f /etc/security/limits.conf ] && sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak.$(date +%Y%m%d-%H%M%S)
  fi
  
  if [ "$needs_sysctl_update" = true ]; then
    [ -f /etc/sysctl.conf ] && sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d-%H%M%S)
  fi
  
  # Configurar limites do sistema (ulimits)
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
  else
    echo_info "✓ Limites do sistema já configurados (pulando)."
  fi
  
  # Configurar parâmetros do kernel
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
    
    # Aplicar configurações imediatamente
    echo_info "Aplicando configurações do kernel..."
    sudo sysctl -p >/dev/null 2>&1
    echo_success "Configurações do kernel aplicadas."
  else
    echo_info "✓ Parâmetros do kernel já configurados (pulando)."
  fi
  
  if [ "$needs_limits_update" = false ] && [ "$needs_sysctl_update" = false ]; then
    echo_success "✓ Todas as otimizações de sistema já estavam aplicadas!"
  else
    echo_success "Otimizações de sistema aplicadas com sucesso!"
  fi
}

optimize_docker_daemon() {
  echo_info "Aplicando otimizações do Docker daemon..."
  
  local docker_daemon_file="/etc/docker/daemon.json"
  local needs_docker_update=false
  
  # Criar diretório se não existir
  sudo mkdir -p /etc/docker
  
  # Verificar se já existe configuração otimizada
  if [ -f "$docker_daemon_file" ]; then
    if grep -q '"log-driver"' "$docker_daemon_file" 2>/dev/null && \
       grep -q '"default-ulimits"' "$docker_daemon_file" 2>/dev/null; then
      echo_info "✓ Docker daemon já possui configurações otimizadas (pulando)."
      needs_docker_update=false
    else
      echo_info "Docker daemon.json existe, mas faltam otimizações. Atualizando..."
      needs_docker_update=true
    fi
  else
    echo_info "Arquivo daemon.json não existe. Criando com otimizações..."
    needs_docker_update=true
  fi
  
  # Só faz backup se for modificar
  if [ "$needs_docker_update" = true ] && [ -f "$docker_daemon_file" ]; then
    sudo cp "$docker_daemon_file" "${docker_daemon_file}.bak.$(date +%Y%m%d-%H%M%S)"
    echo_info "Backup do daemon.json criado."
  fi
  
  # Criar/atualizar arquivo de configuração apenas se necessário
  if [ "$needs_docker_update" = true ]; then
    echo_info "Criando/atualizando arquivo de configuração do Docker daemon..."
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
    
    # Reiniciar Docker para aplicar mudanças
    echo_info "Reiniciando Docker daemon para aplicar configurações..."
    if sudo systemctl restart docker; then
      echo_success "Docker daemon reiniciado com sucesso."
      
      # Aguardar Docker estar pronto
      sleep 3
      
      if docker info >/dev/null 2>&1; then
        echo_success "Docker está funcionando corretamente."
      else
        echo_warning "Docker pode estar demorando para iniciar. Aguarde alguns segundos."
      fi
    else
      echo_warning "Falha ao reiniciar Docker. As configurações serão aplicadas na próxima reinicialização."
    fi
    
    echo_success "Otimizações do Docker aplicadas!"
  else
    echo_success "✓ Docker daemon já estava otimizado!"
  fi
}

check_and_install_dependencies() {
  echo_info "Verificando dependências..."
  install_docker
  install_docker_compose
  install_nodejs
  
  # Aplicar otimizações do sistema após instalar dependências
  echo ""
  echo_info "Aplicando otimizações de performance..."
  optimize_system_performance
  optimize_docker_daemon
  
  echo_success "Todas as dependências necessárias estão presentes ou foram instaladas."
}

# --- Coleta de dados ---
get_environment_tag() {
  echo_info "Selecione o ambiente para as imagens Docker (para operações GHCR):"
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
    *) echo_warning "Opção inválida: $REPLY. Tente novamente." ;;
    esac
  done
  echo_info "Ambiente selecionado para GHCR: $DOCKER_TAG"
}

collect_ghcr_image_details() {
  echo_info "Configuração das Imagens Docker do GHCR:"
  prompt_for_variable "GHCR_IMAGE_USER" "  Usuário/Organização do GitHub para as imagens" "${GHCR_IMAGE_USER_CURRENT}" "oplanov2-entrega" "oplanov2-entrega"
  prompt_for_variable "GHCR_IMAGE_REPO" "  Nome do Repositório no GitHub para as imagens" "${GHCR_IMAGE_REPO_CURRENT}" "entrega-oplanov2" "entrega-oplanov2"
}

collect_traefik_email() {
  echo_info "Configuração do Traefik:"
  prompt_for_variable "EMAIL" "  E-mail para certificados SSL (Traefik)" "${EMAIL_CURRENT}" "" "seu@email.com" validate_email
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
  echo_info "Configuração do Facebook e Instagram (Opcional - deixe em branco se não for usar):"
  prompt_for_variable "FACEBOOK_APP_ID" "  FACEBOOK_APP_ID" "${FACEBOOK_APP_ID_CURRENT}"
  prompt_for_variable "FACEBOOK_APP_SECRET" "  FACEBOOK_APP_SECRET" "${FACEBOOK_APP_SECRET_CURRENT}"
  prompt_for_variable "VERIFY_TOKEN" "  VERIFY_TOKEN (Webhook do Facebook)" "${VERIFY_TOKEN_CURRENT:-$(generate_secure_password 16)}"
  prompt_for_variable "REQUIRE_BUSINESS_MANAGEMENT" "  REQUIRE_BUSINESS_MANAGEMENT (true/false, para frontend)" "${REQUIRE_BUSINESS_MANAGEMENT_CURRENT:-true}"
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
    prompt_for_variable "GERENCIANET_CHAVEPIX" "  CHAVE PIX da Gerencianet" "${GERENCIANET_CHAVEPIX_CURRENT}"
    prompt_for_variable "GERENCIANET_PIX_CERT" "  Caminho do certificado PIX (.p12)" "${GERENCIANET_PIX_CERT_CURRENT}"
    echo_info "Gerencianet será configurado."
  else
    GERENCIANET_SANDBOX=""
    GERENCIANET_CLIENT_ID=""
    GERENCIANET_CLIENT_SECRET=""
    GERENCIANET_CHAVEPIX=""
    GERENCIANET_PIX_CERT=""
    echo_info "Gerencianet não será configurado."
  fi
}

collect_other_configs() {
  echo_info "Outras Configurações:"
  prompt_for_variable "MASTER_KEY" "  MASTER_KEY (Chave mestra para criptografia interna, essencial e única por instalação)" "${MASTER_KEY_CURRENT}"
  if [ -z "$MASTER_KEY" ]; then
    echo_warning "MASTER_KEY não foi definida. É altamente recomendável definir uma."
    read -r -p "Pressione Enter para gerar uma MASTER_KEY automaticamente ou digite uma agora: " user_master_key_input
    if [ -z "$user_master_key_input" ]; then
      MASTER_KEY=$(generate_long_secure_string 16)
      echo_info "MASTER_KEY gerada automaticamente: $MASTER_KEY"
    else
      MASTER_KEY=$user_master_key_input
    fi
  fi
  prompt_for_variable "NUMBER_SUPPORT" "  Número de Suporte (para frontend)" "${NUMBER_SUPPORT_CURRENT}"
}

# --- Geração de credenciais ---
set_credentials_mode() {
  echo_info "Como deseja definir as credenciais para Banco de Dados, RabbitMQ e Redis?"
  options=("Gerar automaticamente (Recomendado)" "Digitar manualmente")
  select opt in "${options[@]}"; do
    case $opt in
    "Gerar automaticamente (Recomendado)")
      CREDENTIAL_MODE="auto"
      break
      ;;
    "Digitar manualmente")
      CREDENTIAL_MODE="manual"
      break
      ;;
    *) echo_warning "Opção inválida: $REPLY. Tente novamente." ;;
    esac
  done
}

set_database_credentials() {
  echo_info "Configurando Credenciais do Banco de Dados (PostgreSQL):"
  if [ "$CREDENTIAL_MODE" == "auto" ]; then
    DB_NAME="oplano_$(generate_secure_password 8)"
    DB_USER="oplano_$(generate_secure_password 8)"
    DB_PASS="$(generate_secure_password 24)"
    echo_info "  Credenciais do Banco de Dados geradas automaticamente."
  else
    prompt_for_variable "DB_NAME" "  Nome do Banco de Dados (DB_NAME)" "${DB_NAME_CURRENT:-oplano}"
    prompt_for_variable "DB_USER" "  Usuário do Banco de Dados (DB_USER)" "${DB_USER_CURRENT:-oplano}"
    prompt_for_variable "DB_PASS" "  Senha do Banco de Dados (DB_PASS)"
  fi
}

set_rabbitmq_credentials() {
  echo_info "Configurando Credenciais do RabbitMQ:"
  if [ "$CREDENTIAL_MODE" == "auto" ]; then
    RABBIT_USER="rabbit_$(generate_secure_password 8)"
    RABBIT_PASS="$(generate_secure_password 24)"
    echo_info "  Credenciais do RabbitMQ geradas automaticamente."
  else
    prompt_for_variable "RABBIT_USER" "  Usuário do RabbitMQ (RABBIT_USER)" "${RABBIT_USER_CURRENT:-oplano}"
    prompt_for_variable "RABBIT_PASS" "  Senha do RabbitMQ (RABBIT_PASS)"
  fi
}

set_redis_credentials() {
  echo_info "Configurando Credenciais do Redis:"
  if [ "$CREDENTIAL_MODE" == "auto" ]; then
    REDIS_PASSWORD="$(generate_secure_password 24)"
    echo_info "  Senha do Redis gerada automaticamente."
  else
    while true; do
      prompt_for_variable "REDIS_PASSWORD" "  Senha do Redis (REDIS_PASSWORD)" "${REDIS_PASSWORD_CURRENT}"
      if [ -n "$REDIS_PASSWORD" ]; then
        break
      fi
      echo_warning "Senha do Redis não pode ficar vazia."
    done
  fi
}


generate_internal_secrets() {
  echo_info "Gerando/Verificando chaves e tokens internos..."
  JWT_SECRET="${JWT_SECRET_CURRENT:-$(openssl rand -base64 44)}"
  JWT_REFRESH_SECRET="${JWT_REFRESH_SECRET_CURRENT:-$(openssl rand -base64 44)}"
  COMPANY_TOKEN="${COMPANY_TOKEN_CURRENT:-$(generate_long_secure_string 16)}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-${REDIS_PASSWORD_CURRENT:-$(generate_secure_password 24)}}"
}

load_env_file() {
  if [ -f "$APP_DIR/$ENV_FILE" ]; then
    echo_info "Carregando configurações existentes de '$APP_DIR/$ENV_FILE'..."
    set -o allexport
    # shellcheck source=/dev/null
    source "$APP_DIR/$ENV_FILE"
    set +o allexport

    # Carrega todas as variáveis existentes
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

    echo_success "Configurações carregadas de '$APP_DIR/$ENV_FILE'."
    return 0
  else
    echo_warning "Arquivo '$APP_DIR/$ENV_FILE' não encontrado. Assumindo nova instalação."
    return 1
  fi
}

save_env_file() {
  echo_info "Salvando configurações em '$APP_DIR/$ENV_FILE'..."
  mkdir -p "$APP_DIR"

  cat >"$APP_DIR/$ENV_FILE" <<EOF
# Versão do Script: $SCRIPT_VERSION
# Data: $(date)

# --- Ambiente ---
NODE_ENV=${NODE_ENV:-production}
DOCKER_TAG=${DOCKER_TAG:-latest}
EMAIL=${EMAIL:-seu@email.com}

# --- Detalhes Imagem GHCR ---
GHCR_IMAGE_USER=${GHCR_IMAGE_USER:-oplanov2-entrega}
GHCR_IMAGE_REPO=${GHCR_IMAGE_REPO:-entrega-oplanov2}

# --- Domínios ---
FRONTEND_DOMAIN=${FRONTEND_DOMAIN}
BACKEND_DOMAIN=${BACKEND_DOMAIN}
FRONTEND_URL=https://${FRONTEND_DOMAIN}
BACKEND_URL=https://${BACKEND_DOMAIN}

# --- Banco de Dados (PostgreSQL) ---
DB_DIALECT=postgres
DB_HOST=whaticket-pgbouncer
DB_PORT=6432
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

# --- RabbitMQ ---
RABBITMQ_HOST=whaticket-rabbitmq
RABBITMQ_PORT=5672
RABBIT_USER=${RABBIT_USER}
RABBIT_PASS=${RABBIT_PASS}
RABBITMQ_URI=amqp://\${RABBIT_USER}:\${RABBIT_PASS}@whaticket-rabbitmq:5672/

# --- Redis ---
REDIS_HOST=whaticket-redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URI=redis://:\${REDIS_PASSWORD}@whaticket-redis:6379

# --- Autenticação e Chaves ---
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
VERIFY_TOKEN=${VERIFY_TOKEN}
ENV_TOKEN=OPLANOV2
COMPANY_TOKEN=${COMPANY_TOKEN}
MASTER_KEY=${MASTER_KEY}

# --- WhatsApp Client Revision ---

# --- Facebook (Opcional) ---
FACEBOOK_APP_ID=${FACEBOOK_APP_ID}
FACEBOOK_APP_SECRET=${FACEBOOK_APP_SECRET}
REQUIRE_BUSINESS_MANAGEMENT=${REQUIRE_BUSINESS_MANAGEMENT}

# --- Gerencianet (Opcional) ---
GERENCIANET_SANDBOX=${GERENCIANET_SANDBOX}
GERENCIANET_CLIENT_ID=${GERENCIANET_CLIENT_ID}
GERENCIANET_CLIENT_SECRET=${GERENCIANET_CLIENT_SECRET}
GERENCIANET_CHAVEPIX=${GERENCIANET_CHAVEPIX}
GERENCIANET_PIX_CERT=${GERENCIANET_PIX_CERT}

# --- Outras ---
PROXY_PORT=443
TIMEOUT_TO_IMPORT_MESSAGE=100
NUMBER_SUPPORT=${NUMBER_SUPPORT}
EOF
  echo_success "Configurações salvas em '$APP_DIR/$ENV_FILE'."
}

docker_login() {
  if grep -q '"ghcr.io"' ~/.docker/config.json 2>/dev/null; then
    echo_success "Login no GitHub Container Registry já existe, pulando etapa de login."
    return 0
  fi

  local ghcr_user_login
  local ghcr_token
  echo_info "Login no GitHub Container Registry (GHCR)"
  while true; do
    read -r -p "  Digite o seu usuário do GitHub para LOGIN no GHCR: " ghcr_user_login
    read -s -r -p "  Digite o seu Token de Acesso Pessoal (PAT) do GitHub (escopo: read:packages ou write:packages): " ghcr_token
    echo
    if [ -n "$ghcr_user_login" ] && [ -n "$ghcr_token" ]; then
      break
    else
      echo_warning "Usuário e token do GitHub para login não podem ser vazios. Tente novamente."
    fi
  done

  echo_info "Tentando login no GHCR com o usuário '$ghcr_user_login'..."
  if echo "$ghcr_token" | docker login ghcr.io -u "$ghcr_user_login" --password-stdin; then
    echo_success "Login no GitHub Container Registry realizado com sucesso."
  else
    echo_error "Falha no login do GHCR. Verifique o usuário, token e sua conexão com a internet."
  fi
}

adjust_docker_compose_images() {
  local target_compose_file="$APP_DIR/docker-compose.yml"
  if [ ! -f "$target_compose_file" ]; then
    echo_error "Arquivo docker-compose.yml não encontrado em $target_compose_file para ajuste."
    return 1
  fi

  echo_info "Ajustando nomes das imagens no docker-compose.yml..."

  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    if [ -z "$GHCR_IMAGE_USER" ] || [ -z "$GHCR_IMAGE_REPO" ]; then
      echo_error "GHCR_IMAGE_USER ou GHCR_IMAGE_REPO não definidos. Não é possível ajustar o docker-compose.yml."
      return 1
    fi
    sed -i.bak \
      -e "s|ghcr.io/seu-usuario/seu-repositorio/backend|ghcr.io/${GHCR_IMAGE_USER}/${GHCR_IMAGE_REPO}/backend|g" \
      -e "s|ghcr.io/seu-usuario/seu-repositorio/frontend|ghcr.io/${GHCR_IMAGE_USER}/${GHCR_IMAGE_REPO}/frontend|g" \
      "$target_compose_file"
    echo_success "docker-compose.yml ajustado para usar imagens GHCR: ghcr.io/${GHCR_IMAGE_USER}/${GHCR_IMAGE_REPO}/<servico>:\${DOCKER_TAG}"
  elif [ "$OPERATION_TYPE" == "local_build" ]; then
    sed -i.bak \
      -e "s|image: ghcr.io/seu-usuario/seu-repositorio/backend:\${DOCKER_TAG}|image: oplano/backend:${DOCKER_TAG}|g" \
      -e "s|image: ghcr.io/seu-usuario/seu-repositorio/frontend:\${DOCKER_TAG}|image: oplano/frontend:${DOCKER_TAG}|g" \
      "$target_compose_file"
    echo_success "docker-compose.yml ajustado para usar imagens locais: oplano/<servico>:${DOCKER_TAG}"
  fi
  rm -f "${target_compose_file}.bak"
}

copy_docker_compose_template_and_adjust() {
  echo_info "Copiando template docker-compose.yml..."

  # Verifica se o template existe
  if [ ! -f "$DOCKER_COMPOSE_TEMPLATE_PATH" ]; then
    echo_error "Arquivo template docker-compose.yml não encontrado em $DOCKER_COMPOSE_TEMPLATE_PATH."
  fi

  # Garante que o diretório de destino existe
  mkdir -p "$APP_DIR"

  # Copia o template
  cp -f "$DOCKER_COMPOSE_TEMPLATE_PATH" "$APP_DIR/docker-compose.yml"
  echo_success "Template docker-compose.yml copiado para $APP_DIR/docker-compose.yml"

  # Ajusta as imagens
  adjust_docker_compose_images
}

sync_config_templates() {
  echo_info "Sincronizando arquivos de configuração auxiliares..."

  if [ ! -d "$CONFIG_TEMPLATE_DIR" ]; then
    echo_warning "Diretório de templates de configuração '$CONFIG_TEMPLATE_DIR' não encontrado. Pulando sincronização."
    return
  fi

  local config_dir="$APP_DIR/config"
  mkdir -p "$config_dir"
  
  local files=()

  if [ ${#files[@]} -eq 0 ]; then
    echo_info "Nenhum arquivo de configuração estático para sincronizar. Arquivos são gerados dinamicamente."
    return
  fi

  for rel_path in "${files[@]}"; do
    local source_file="$CONFIG_TEMPLATE_DIR/$rel_path"
    local target_file="$config_dir/$rel_path"
    local target_parent
    target_parent=$(dirname "$target_file")

    if [ ! -f "$source_file" ]; then
      echo_warning "Arquivo de template '$source_file' não encontrado."
      continue
    fi

    mkdir -p "$target_parent"

    if [ -d "$target_file" ]; then
      echo_warning "Corrigindo caminho '$target_file' que era um diretório. Removendo antes de substituir por arquivo."
      rm -rf "$target_file"
    fi

    cp -f "$source_file" "$target_file"
  done

  echo_success "Configurações auxiliares atualizadas em '$config_dir'."
}

generate_rabbitmq_config() {
  echo_info "Gerando arquivo de configuração do RabbitMQ..."
  
  local rabbitmq_dir="$APP_DIR/config/rabbitmq"
  mkdir -p "$rabbitmq_dir"

  local source_template="$CONFIG_TEMPLATE_DIR/rabbitmq/rabbitmq.conf"
  local target_file="$rabbitmq_dir/rabbitmq.conf"

  if [ ! -f "$source_template" ]; then
    echo_warning "Template do RabbitMQ não encontrado em '$source_template'. Pulando geração."
    return
  fi

  # Copia o template e substitui as variáveis
  cp -f "$source_template" "$target_file"
  sed -i "s/\${RABBIT_USER}/${RABBIT_USER}/g" "$target_file"
  sed -i "s/\${RABBIT_PASS}/${RABBIT_PASS}/g" "$target_file"

  echo_success "Arquivo de configuração do RabbitMQ gerado:"
  echo_info "  - $target_file"
}

generate_pgbouncer_config() {
  echo_info "Gerando arquivos de configuração do PgBouncer..."
  
  local pgbouncer_dir="$APP_DIR/config/pgbouncer"
  mkdir -p "$pgbouncer_dir"

  # Gera pgbouncer.ini
  cat >"$pgbouncer_dir/pgbouncer.ini" <<'PGBOUNCER_INI'
[databases]
;; Aliases for your databases
* = host=whaticket-postgres port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

;; Pool settings optimized for OnTicket
pool_mode = transaction
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 10
reserve_pool_timeout = 5.0
max_client_conn = 400
max_db_connections = 100

;; Connection management
server_reset_query = DISCARD ALL
server_lifetime = 3600
server_idle_timeout = 600
client_login_timeout = 60

;; Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits

;; Admin settings
admin_users = ${DB_USER}
stats_users = ${DB_USER}
PGBOUNCER_INI

  sed -i "s/\${DB_USER}/${DB_USER}/g" "$pgbouncer_dir/pgbouncer.ini"
  cat >"$pgbouncer_dir/userlist.txt" <<EOF
"${DB_USER}" "${DB_PASS}"
EOF

  echo_success "Arquivos de configuração do PgBouncer gerados:"
  echo_info "  - $pgbouncer_dir/pgbouncer.ini"
  echo_info "  - $pgbouncer_dir/userlist.txt"
}

docker_compose_pull() {
  echo_info "Atualizando imagens Docker (docker compose pull)..."
  cd "$APP_DIR" || echo_error "Não foi possível acessar o diretório $APP_DIR"

  # Verifica se o arquivo docker-compose.yml existe
  if [ ! -f "docker-compose.yml" ]; then
    echo_error "Arquivo docker-compose.yml não encontrado em $APP_DIR"
  fi

  # Verifica se o arquivo .env existe
  if [ ! -f ".env" ]; then
    echo_error "Arquivo .env não encontrado em $APP_DIR"
  fi

  if docker compose pull; then
    echo_success "Imagens Docker atualizadas."
  else
    echo_error "Falha ao atualizar imagens Docker. Verifique se você está logado no GHCR se estiver usando imagens de lá."
  fi
}

docker_compose_up() {
  echo_info "Iniciando/Reiniciando serviços com Docker Compose..."
  cd "$APP_DIR" || echo_error "Não foi possível acessar o diretório $APP_DIR"

  # Verifica se o arquivo docker-compose.yml existe
  if [ ! -f "docker-compose.yml" ]; then
    echo_error "Arquivo docker-compose.yml não encontrado em $APP_DIR"
  fi

  # Verifica se o arquivo .env existe
  if [ ! -f ".env" ]; then
    echo_error "Arquivo .env não encontrado em $APP_DIR"
  fi

  echo_info "Executando docker compose a partir de: $(pwd)"
  echo_info "Usando arquivo .env de: $APP_DIR/.env"

  # Garante que as variáveis de ambiente sejam carregadas
  set -o allexport
  source "$APP_DIR/$ENV_FILE"
  set +o allexport

  if docker compose up -d --remove-orphans; then
    echo_success "Serviços Docker iniciados/reiniciados com sucesso."
    echo_info "Aguarde alguns instantes para que todos os serviços estejam operacionais."
    echo ""
    echo_info "Para verificar os logs, use:"
    echo "  ${COLOR_GREEN}cd $APP_DIR && docker compose logs -f${COLOR_RESET}"
    echo ""
    echo_info "Para verificar o status dos serviços:"
    echo "  ${COLOR_GREEN}cd $APP_DIR && docker compose ps${COLOR_RESET}"
  else
    echo_error "Falha ao iniciar/reiniciar serviços Docker. Verifique os logs com 'cd $APP_DIR && docker compose logs'."
  fi
}

show_summary_and_confirm() {
  echo "${COLOR_CYAN}================ Resumo das Configurações ================${COLOR_RESET}"
  echo "  E-mail Traefik:         ${COLOR_YELLOW}${EMAIL}${COLOR_RESET}"
  echo "  URL Frontend:           ${COLOR_YELLOW}https://${FRONTEND_DOMAIN}${COLOR_RESET}"
  echo "  URL Backend:            ${COLOR_YELLOW}https://${BACKEND_DOMAIN}${COLOR_RESET}"
  echo ""
  echo "  Ambiente (NODE_ENV):    ${COLOR_YELLOW}${NODE_ENV}${COLOR_RESET}"
  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    echo "  Docker Tag (GHCR):      ${COLOR_YELLOW}${DOCKER_TAG}${COLOR_RESET}"
    echo "  Usuário Imagem GHCR:    ${COLOR_YELLOW}${GHCR_IMAGE_USER}${COLOR_RESET}"
    echo "  Repositório Imagem GHCR:${COLOR_YELLOW}${GHCR_IMAGE_REPO}${COLOR_RESET}"
    if [ -n "$ghcr_user_login" ]; then
      echo "  Usuário Login GHCR:     ${COLOR_YELLOW}${ghcr_user_login}${COLOR_RESET}"
    fi
  else
    echo "  Build Local:            ${COLOR_YELLOW}Sim${COLOR_RESET}"
    echo "  Repositório Git:        ${COLOR_YELLOW}${REPO_URL}${COLOR_RESET}"
  fi
  echo ""
  echo "  Banco de Dados (Nome):  ${COLOR_YELLOW}${DB_NAME}${COLOR_RESET}"
  echo "  Banco de Dados (User):  ${COLOR_YELLOW}${DB_USER}${COLOR_RESET}"
  echo "  RabbitMQ (User):        ${COLOR_YELLOW}${RABBIT_USER}${COLOR_RESET}"
  echo "  Redis Password:        ${COLOR_YELLOW}${REDIS_PASSWORD}${COLOR_RESET}"
  echo ""
  echo "  MASTER_KEY:             ${COLOR_YELLOW}${MASTER_KEY:0:8}... (oculto)${COLOR_RESET}"
  echo "${COLOR_CYAN}========================================================${COLOR_RESET}"
  echo ""
  read -r -p "As configurações acima estão corretas? Deseja prosseguir? (s/N): " confirmation
  if [[ "$confirmation" != "s" && "$confirmation" != "S" ]]; then
    echo_error "Operação cancelada pelo usuário."
  fi
}

collect_all_data_new_install() {
  collect_traefik_email
  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    get_environment_tag
    collect_ghcr_image_details
  else
    prompt_for_variable "NODE_ENV" "  Ambiente de execução (NODE_ENV para build local)" "${NODE_ENV_CURRENT:-production}" "production" "production ou development"
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

collect_data_update() {
  echo_info "Carregando configurações existentes para atualização..."
  if ! load_env_file; then
    echo_warning "Nenhum arquivo '$APP_DIR/$ENV_FILE' encontrado. Não é possível atualizar."
    read -r -p "Deseja prosseguir com uma Nova Instalação? (s/N): " choice
    if [[ "$choice" == "s" || "$choice" == "S" ]]; then
      if [ "$OPERATION_TYPE" == "ghcr" ]; then
        run_new_ghcr_installation
      else
        run_new_local_build_installation
      fi
      exit 0
    else
      echo_error "Atualização cancelada. Arquivo de configuração não encontrado."
    fi
  fi

  echo_info "Você pode revisar e alterar as configurações. Pressione Enter para manter o valor atual."
  collect_traefik_email

  if [ "$OPERATION_TYPE" == "ghcr" ]; then
    DOCKER_TAG_OLD="$DOCKER_TAG_CURRENT"
    get_environment_tag
    if [ "$DOCKER_TAG" != "$DOCKER_TAG_OLD" ]; then
      echo_info "Tag Docker (GHCR) alterada de '$DOCKER_TAG_OLD' para '$DOCKER_TAG'."
    fi
    collect_ghcr_image_details
  else
    prompt_for_variable "NODE_ENV" "  Ambiente de execução (NODE_ENV para build local)" "${NODE_ENV_CURRENT:-production}"
    DOCKER_TAG="local"
  fi

  collect_domains
  collect_facebook_credentials
  collect_gerencianet_credentials
  collect_other_configs

  echo_info "Credenciais de Banco de Dados, RabbitMQ e Redis: Para alterá-las, edite o arquivo '$APP_DIR/$ENV_FILE' manualmente ANTES de rodar a atualização, ou use a opção de Resetar Instalação."
  DB_NAME="$DB_NAME_CURRENT"
  DB_USER="$DB_USER_CURRENT"
  prompt_for_variable "DB_PASS" "  Senha do Banco de Dados (DB_PASS)" "" "" "Deixe em branco para NÃO alterar se já existir"
  DB_PASS=${DB_PASS:-$DB_PASS_CURRENT}

  RABBIT_USER="$RABBIT_USER_CURRENT"
  prompt_for_variable "RABBIT_PASS" "  Senha do RabbitMQ (RABBIT_PASS)" "" "" "Deixe em branco para NÃO alterar"
  RABBIT_PASS=${RABBIT_PASS:-$RABBIT_PASS_CURRENT}

  prompt_for_variable "REDIS_PASSWORD" "  Senha do Redis" "${REDIS_PASSWORD_CURRENT}" "" "Deixe em branco para NÃO alterar"
  REDIS_PASSWORD=${REDIS_PASSWORD:-$REDIS_PASSWORD_CURRENT}

  generate_internal_secrets
}

run_new_ghcr_installation() {
  OPERATION_TYPE="ghcr"
  echo_info "Iniciando Nova Instalação (Imagens Remotas GHCR)..."
  collect_all_data_new_install
  show_summary_and_confirm
  save_env_file
  copy_docker_compose_template_and_adjust
  sync_config_templates
  generate_pgbouncer_config
  generate_rabbitmq_config
  docker_login
  docker_compose_pull
  docker_compose_up
  echo_success "Nova Instalação (GHCR) concluída!"
  show_post_install_info
}

run_update_ghcr_installation() {
  OPERATION_TYPE="ghcr"
  echo_info "Iniciando Atualização da Instalação (Imagens Remotas GHCR)..."
  collect_data_update
  show_summary_and_confirm
  save_env_file
  copy_docker_compose_template_and_adjust
  sync_config_templates
  generate_pgbouncer_config
  generate_rabbitmq_config
  docker_login
  docker_compose_pull
  docker_compose_up
  echo_success "Atualização da Instalação (GHCR) concluída!"
  show_post_install_info
}

setup_local_repo() {
  prompt_for_variable "REPO_URL" "  URL do repositório Git (HTTPS)" "${REPO_URL_CURRENT}" "https://github.com/seu-usuario/seu-repositorio.git" "https://github.com/seu-usuario/seu-repositorio.git"
  prompt_for_variable "REPO_BRANCH" "  Branch do repositório Git" "${REPO_BRANCH_CURRENT:-main}" "main" "main ou develop"
  read -r -p "  O repositório é privado e requer um token de acesso? (s/N): " private_repo_choice
  if [[ "$private_repo_choice" == "s" || "$private_repo_choice" == "S" ]]; then
    prompt_for_variable "REPO_TOKEN" "  Token de acesso ao repositório (PAT)" "" "" "ghp_xxx..."
  else
    REPO_TOKEN=""
  fi

  REPO_URL_CURRENT="$REPO_URL"
  REPO_BRANCH_CURRENT="$REPO_BRANCH"

  local repo_source_dir="$APP_DIR/source_code"
  mkdir -p "$repo_source_dir"

  if [ ! -d "$repo_source_dir/.git" ]; then
    echo_info "Clonando repositório de $REPO_URL (branch: $REPO_BRANCH) em $repo_source_dir..."
    local clone_url="$REPO_URL"
    if [ -n "$REPO_TOKEN" ]; then
      clone_url="https://${REPO_TOKEN}@${REPO_URL#https://}"
    fi
    if git clone --branch "$REPO_BRANCH" "$clone_url" "$repo_source_dir"; then
      echo_success "Repositório clonado com sucesso."
    else
      echo_error "Falha ao clonar o repositório. Verifique a URL, branch, token e permissões."
    fi
  else
    echo_info "Repositório local encontrado em $repo_source_dir. Atualizando (git pull)..."
    cd "$repo_source_dir"
    git stash push -u
    if git checkout "$REPO_BRANCH" && git pull origin "$REPO_BRANCH"; then
      echo_success "Repositório atualizado com sucesso."
      git stash pop || echo_info "Nenhum stash para aplicar."
    else
      git stash pop || true
      echo_error "Falha ao atualizar o repositório. Verifique o status do git em $repo_source_dir."
    fi
    cd "$APP_DIR"
  fi
}

build_local_images() {
  local repo_source_dir="$APP_DIR/source_code"
  if [ ! -d "$repo_source_dir" ]; then
    echo_error "Diretório de código fonte $repo_source_dir não encontrado. Execute o setup do repositório primeiro."
  fi

  echo_info "Iniciando build das imagens Docker locais..."
  for svc in backend frontend; do
    local dockerfile_path="$repo_source_dir/$svc/Dockerfile"
    local context_path="$repo_source_dir/$svc"
    local image_name="oplano/${svc}:${DOCKER_TAG}"

    if [ -f "$dockerfile_path" ]; then
      echo_info "Buildando imagem $image_name a partir de $context_path..."
      if docker build -t "$image_name" --build-arg NODE_ENV="$NODE_ENV" "$context_path"; then
        echo_success "Imagem $image_name buildada com sucesso."
      else
        echo_error "Falha ao buildar a imagem $image_name."
      fi
    else
      echo_warning "Dockerfile para o serviço '$svc' não encontrado em '$dockerfile_path'. Pulando build."
    fi
  done
  copy_docker_compose_template_and_adjust
}

run_new_local_build_installation() {
  OPERATION_TYPE="local_build"
  echo_info "Iniciando Nova Instalação (Build Local das Imagens)..."
  setup_local_repo
  collect_all_data_new_install
  show_summary_and_confirm
  save_env_file
  build_local_images
  sync_config_templates
  generate_pgbouncer_config
  generate_rabbitmq_config
  docker_compose_up
  echo_success "Nova Instalação (Build Local) concluída!"
  show_post_install_info
}

run_update_local_build_installation() {
  OPERATION_TYPE="local_build"
  echo_info "Iniciando Atualização da Instalação (Build Local das Imagens)..."
  setup_local_repo
  collect_data_update
  show_summary_and_confirm
  save_env_file
  build_local_images
  sync_config_templates
  generate_pgbouncer_config
  generate_rabbitmq_config
  docker_compose_up
  echo_success "Atualização da Instalação (Build Local) concluída!"
  show_post_install_info
}

run_reset_installation() {
  echo_warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo_warning "!!! ATENÇÃO: ESTA OPERAÇÃO É DESTRUTIVA E IRREVERSÍVEL !!!"
  echo_warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo_info "Esta operação irá:"
  echo_info "  1. Parar e remover todos os contêineres da aplicação (definidos em docker-compose.yml)."
  echo_info "  2. Remover os volumes Docker associados (PERDA DE DADOS: postgres_data, redis_data, etc.)."
  echo_info "  3. Apagar o arquivo de configuração principal '$APP_DIR/$ENV_FILE'."
  echo_info "  4. Apagar o diretório de código fonte baixado ($APP_DIR/source_code) se existir."
  echo_info "  5. Limpar o sistema Docker de imagens e volumes órfãos."
  echo ""
  read -r -p "Você tem certeza absoluta que deseja resetar a instalação? (Digite 'SIM' para confirmar): " confirmation
  if [ "$confirmation" != "SIM" ]; then
    echo_info "Reset cancelado pelo usuário."
    exit 0
  fi

  echo_info "Iniciando reset da instalação..."

  if [ -f "$APP_DIR/docker-compose.yml" ] && [ -f "$APP_DIR/.env" ]; then
    echo_info "Parando e removendo contêineres e volumes Docker..."
    cd "$APP_DIR" || echo_warning "Não foi possível acessar $APP_DIR"
    if docker compose down --volumes --remove-orphans; then
      echo_success "Contêineres Docker e volumes associados parados e removidos."
    else
      echo_warning "Falha ao parar/remover contêineres com Docker Compose."
    fi
  else
    echo_warning "Arquivo docker-compose.yml ou .env não encontrado em $APP_DIR. Pulando 'docker compose down'."
  fi

  echo_info "Limpando sistema Docker (docker system prune)..."
  if docker system prune -af --volumes; then
    echo_success "Sistema Docker limpo."
  else
    echo_warning "Falha ao limpar o sistema Docker."
  fi

  if [ -f "$APP_DIR/$ENV_FILE" ]; then
    echo_info "Removendo arquivo de configuração principal '$APP_DIR/$ENV_FILE'..."
    rm -f "$APP_DIR/$ENV_FILE"
    echo_success "Arquivo '$APP_DIR/$ENV_FILE' removido."
  else
    echo_info "Arquivo de configuração principal '$APP_DIR/$ENV_FILE' não encontrado."
  fi

  if [ -d "$APP_DIR/source_code" ]; then
    echo_info "Removendo diretório de código fonte '$APP_DIR/source_code'..."
    rm -rf "$APP_DIR/source_code"
    echo_success "Diretório de código fonte removido."
  fi

  if [ -f "$APP_DIR/docker-compose.yml" ]; then
    echo_info "Removendo arquivo docker-compose.yml da aplicação..."
    rm -f "$APP_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml.bak" 2>/dev/null
    echo_success "Arquivo docker-compose.yml removido."
  fi

  if [ -d "$CONFIG_DIR" ]; then
    echo_info "Removendo diretório de configurações auxiliares '$CONFIG_DIR'..."
    rm -rf "$CONFIG_DIR"
    echo_success "Diretório de configurações removido."
  fi

  # Volta para o diretório do instalador
  cd "$INSTALLER_DIR" || true

  echo_success "Reset da instalação concluído!"
  echo_info "Você pode agora executar uma nova instalação se desejar."
}

show_post_install_info() {
  echo ""
  echo "${COLOR_CYAN}=====================================================${COLOR_RESET}"
  echo "${COLOR_GREEN}🎉 Instalação/Atualização Concluída com Sucesso! 🎉${COLOR_RESET}"
  echo "${COLOR_CYAN}=====================================================${COLOR_RESET}"
  echo ""
  echo "${COLOR_YELLOW}📋 Informações Importantes:${COLOR_RESET}"
  echo ""
  echo "  🌐 URLs da Aplicação:"
  echo "     Frontend: ${COLOR_GREEN}https://${FRONTEND_DOMAIN}${COLOR_RESET}"
  echo "     Backend:  ${COLOR_GREEN}https://${BACKEND_DOMAIN}${COLOR_RESET}"
  echo ""
  echo "  🔐 Redis:"
  echo "     Senha:   ${COLOR_YELLOW}${REDIS_PASSWORD}${COLOR_RESET}"
  echo ""
  echo "  📦 Banco de Dados PostgreSQL:"
  echo "     Nome:    ${COLOR_YELLOW}${DB_NAME}${COLOR_RESET}"
  echo "     Usuário: ${COLOR_YELLOW}${DB_USER}${COLOR_RESET}"
  echo ""
  echo "${COLOR_CYAN}📝 Comandos Úteis:${COLOR_RESET}"
  echo "  Ver logs de todos os serviços:"
  echo "    ${COLOR_GREEN}cd $APP_DIR && docker compose logs -f${COLOR_RESET}"
  echo ""
  echo "  Ver logs de um serviço específico:"
  echo "    ${COLOR_GREEN}cd $APP_DIR && docker compose logs -f backend${COLOR_RESET}"
  echo "    ${COLOR_GREEN}cd $APP_DIR && docker compose logs -f frontend${COLOR_RESET}"
  echo ""
  echo "  Verificar status dos serviços:"
  echo "    ${COLOR_GREEN}cd $APP_DIR && docker compose ps${COLOR_RESET}"
  echo ""
  echo "  Reiniciar um serviço:"
  echo "    ${COLOR_GREEN}cd $APP_DIR && docker compose restart backend${COLOR_RESET}"
  echo ""
  echo "${COLOR_YELLOW}⚠️  Importante:${COLOR_RESET}"
  echo "  - Aguarde alguns minutos para todos os serviços iniciarem completamente"
  echo "  - O certificado SSL pode levar alguns minutos para ser gerado na primeira vez"
  echo "  - Suas configurações foram salvas em: ${COLOR_YELLOW}$APP_DIR/$ENV_FILE${COLOR_RESET}"
  echo "  - ${COLOR_RED}MANTENHA ESTE ARQUIVO SEGURO!${COLOR_RESET} Ele contém todas as senhas e chaves"
  echo ""
  echo "${COLOR_CYAN}=====================================================${COLOR_RESET}"
}

main_menu_header() {
  clear
  echo "${COLOR_CYAN}=====================================================${COLOR_RESET}"
  echo "${COLOR_CYAN}  🚀 Instalador OPLANO - Versão $SCRIPT_VERSION ${COLOR_RESET}"
  echo "${COLOR_CYAN}  📦 Sistema Completo de Gestão WhatsApp ${COLOR_RESET}"
  echo "${COLOR_CYAN}  👨‍💻 Autor: Joseph Fernandes ${COLOR_RESET}"
  echo "${COLOR_CYAN}=====================================================${COLOR_RESET}"
  echo ""
}

select_operation_mode() {
  main_menu_header
  echo "Escolha a operação desejada:"
  echo ""
  echo "${COLOR_GREEN}🐳 Imagens Remotas (GHCR) - Recomendado${COLOR_RESET}"
  echo "  1) Nova Instalação (usando imagens do GHCR)"
  echo "  2) Atualizar Instalação (usando imagens do GHCR)"
  echo ""
  echo "${COLOR_YELLOW}🔨 Build Local de Imagens (Avançado)${COLOR_RESET}"
  echo "  3) Nova Instalação (buildando imagens localmente a partir do Git)"
  echo "  4) Atualizar Instalação (re-buildando imagens localmente a partir do Git)"
  echo ""
  echo "${COLOR_RED}🔧 Manutenção${COLOR_RESET}"
  echo "  5) Resetar Instalação Completa (⚠️  PERDA DE DADOS)"
  echo ""
  echo "  6) Sair"
  echo ""
  while true; do
    read -rp "Digite o número da opção desejada: " opt
    case $opt in
    1)
      OPERATION_MODE="new_ghcr"
      break
      ;;
    2)
      OPERATION_MODE="update_ghcr"
      break
      ;;
    3)
      OPERATION_MODE="new_local"
      break
      ;;
    4)
      OPERATION_MODE="update_local"
      break
      ;;
    5)
      OPERATION_MODE="reset"
      break
      ;;
    6)
      echo_info "Saindo..."
      exit 0
      ;;
    *) echo_warning "Opção inválida: $opt. Tente novamente." ;;
    esac
  done
}

# --- Início da Execução ---
check_interactive_terminal
check_and_install_dependencies

# Cria o diretório da aplicação se não existir
mkdir -p "$APP_DIR"

# Salva o diretório atual do instalador
INSTALLER_DIR="$(pwd)"
echo_info "Diretório do instalador: $INSTALLER_DIR"
echo_info "Diretório da aplicação: $APP_DIR"

# Define o caminho do template baseado no diretório do instalador
if [ ! -f "$DOCKER_COMPOSE_TEMPLATE_PATH" ]; then
  # Tenta encontrar o template no diretório atual
  if [ -f "./docker-compose.yml" ]; then
    DOCKER_COMPOSE_TEMPLATE_PATH="$(pwd)/docker-compose.yml"
    echo_info "Template docker-compose.yml encontrado em: $DOCKER_COMPOSE_TEMPLATE_PATH"
  else
    echo_error "Template docker-compose.yml não encontrado. Certifique-se de executar o script do diretório do instalador."
  fi
fi

if [ ! -d "$CONFIG_TEMPLATE_DIR" ]; then
  if [ -d "$INSTALLER_DIR/config" ]; then
    CONFIG_TEMPLATE_DIR="$INSTALLER_DIR/config"
    echo_info "Templates de configuração encontrados em: $CONFIG_TEMPLATE_DIR"
  else
    echo_warning "Diretório de templates de configuração '$CONFIG_TEMPLATE_DIR' não encontrado."
  fi
fi

select_operation_mode

case "$OPERATION_MODE" in
"new_ghcr")
  run_new_ghcr_installation
  ;;
"update_ghcr")
  run_update_ghcr_installation
  ;;
"new_local")
  run_new_local_build_installation
  ;;
"update_local")
  run_update_local_build_installation
  ;;
"reset")
  run_reset_installation
  ;;
*)
  echo_error "Modo de operação desconhecido: $OPERATION_MODE"
  ;;
esac

exit 0
