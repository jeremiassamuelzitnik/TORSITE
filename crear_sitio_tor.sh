#!/usr/bin/env bash
#
# crear_sitio_tor.sh
# Crea un sitio web servido con nginx dentro de Docker, publicado
# como servicio oculto de Tor (.onion), en Debian/Ubuntu.
#
# Uso:  sudo bash crear_sitio_tor.sh
#
set -euo pipefail

# ---------- Colores ----------
C_INFO='\033[1;34m'
C_OK='\033[1;32m'
C_WARN='\033[1;33m'
C_ERR='\033[1;31m'
C_RST='\033[0m'

info()  { echo -e "${C_INFO}[*]${C_RST} $*"; }
ok()    { echo -e "${C_OK}[OK]${C_RST} $*"; }
warn()  { echo -e "${C_WARN}[!]${C_RST} $*"; }
err()   { echo -e "${C_ERR}[ERROR]${C_RST} $*" >&2; }

# ---------- Comprobaciones previas ----------
if [[ $EUID -ne 0 ]]; then
  err "Este script debe ejecutarse como root (usá: sudo bash $0)"
  exit 1
fi

if ! grep -qEi 'debian|ubuntu' /etc/os-release 2>/dev/null; then
  warn "No se detectó Debian/Ubuntu. El script continúa igual, pero podría fallar."
fi

# Solicitar directorio base
read -rp "Indique el directorio base [/opt]: " BASE_DIR
BASE_DIR="${BASE_DIR:-/opt}"

# Normalizar (elimina la barra final si existe, excepto si es /)
BASE_DIR="${BASE_DIR%/}"
[[ -z "$BASE_DIR" ]] && BASE_DIR="/"

# Validaciones
if [[ ! -d "$BASE_DIR" ]]; then
    echo "Error: El directorio '$BASE_DIR' no existe."
    exit 1
fi

if [[ ! -w "$BASE_DIR" ]]; then
    echo "Error: No tiene permisos de escritura sobre '$BASE_DIR'."
    exit 1
fi

# ---------- Preguntas interactivas ----------
echo "=================================================================="
echo " Asistente de creación de sitio web en Tor (Docker + nginx)"
echo "=================================================================="

read -rp "Nombre del sitio (se usará como nombre de carpeta en ${BASE_DIR}): " SITENAME
SITENAME=$(echo "$SITENAME" | tr -cd 'a-zA-Z0-9_-')
if [[ -z "$SITENAME" ]]; then
  err "Nombre de sitio inválido."
  exit 1
fi

SITE_DIR="${BASE_DIR}/${SITENAME}"
if [[ -d "$SITE_DIR" ]]; then
  err "Ya existe ${SITE_DIR}. Elegí otro nombre o borrá la carpeta existente."
  exit 1
fi

read -rp "Puerto interno local para nginx (127.0.0.1, default 8080): " HTTPPORT
HTTPPORT=${HTTPPORT:-8080}

read -rp "¿Necesitás base de datos? (s/n): " NEED_DB
NEED_DB=${NEED_DB,,}

DB_TYPE=""
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_ROOT_PASS=""

if [[ "$NEED_DB" == "s" || "$NEED_DB" == "si" || "$NEED_DB" == "y" ]]; then
  echo "Elegí el motor de base de datos:"
  echo "  1) MySQL"
  echo "  2) MariaDB"
  echo "  3) PostgreSQL"
  echo "  4) MongoDB"
  read -rp "Opción [1-4]: " DB_OPT

  case "$DB_OPT" in
    1) DB_TYPE="mysql" ;;
    2) DB_TYPE="mariadb" ;;
    3) DB_TYPE="postgres" ;;
    4) DB_TYPE="mongo" ;;
    *) err "Opción inválida"; exit 1 ;;
  esac

  read -rp "Nombre de la base de datos [app_db]: " DB_NAME
  DB_NAME=${DB_NAME:-app_db}
  read -rp "Usuario de la base de datos [app_user]: " DB_USER
  DB_USER=${DB_USER:-app_user}
  read -rsp "Contraseña para ese usuario (enter = generar aleatoria): " DB_PASS
  echo
  if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')
    info "Se generó una contraseña aleatoria para el usuario de la DB."
  fi
  if [[ "$DB_TYPE" == "mysql" || "$DB_TYPE" == "mariadb" ]]; then
    DB_ROOT_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')
  fi
fi

echo
info "Resumen:"
echo "  Sitio:        $SITENAME"
echo "  Carpeta:      $SITE_DIR"
echo "  Puerto local: 127.0.0.1:${HTTPPORT}"
echo "  Base datos:   ${DB_TYPE:-ninguna}"
read -rp "¿Confirmás y continuás? (s/n): " CONFIRM
if [[ "${CONFIRM,,}" != "s" && "${CONFIRM,,}" != "si" && "${CONFIRM,,}" != "y" ]]; then
  echo "Cancelado."
  exit 0
fi

# ---------- Actualización del sistema ----------
info "Actualizando el sistema (apt update && upgrade)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# ---------- Instalación de dependencias base ----------
info "Instalando dependencias base (curl, gnupg, ca-certificates, openssl, tor)..."
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  openssl \
  tor \
  apt-transport-https

# ---------- Instalación de Docker ----------
if ! command -v docker &>/dev/null; then
  info "Instalando Docker Engine y Docker Compose plugin..."
  install -m 0755 -d /etc/apt/keyrings
  DISTRO_ID=$(. /etc/os-release && echo "$ID")
  curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO_ID} \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker ya estaba instalado."
fi

# ---------- Estructura de carpetas ----------
info "Creando estructura en ${SITE_DIR}..."
mkdir -p "${SITE_DIR}/html"
mkdir -p "${SITE_DIR}/nginx"
if [[ -n "$DB_TYPE" ]]; then
  mkdir -p "${SITE_DIR}/db_data"
fi

# ---------- Página de ejemplo ----------
cat > "${SITE_DIR}/html/index.html" <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>${SITENAME}</title>
</head>
<body>
  <h1>Bienvenido a ${SITENAME}</h1>
  <p>Este sitio corre dentro de Docker y se publica como servicio oculto de Tor.</p>
</body>
</html>
EOF

# ---------- Configuración de nginx ----------
cat > "${SITE_DIR}/nginx/default.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

# ---------- docker-compose.yml ----------
COMPOSE_FILE="${SITE_DIR}/docker-compose.yml"

{
  echo "services:"
  echo "  web:"
  echo "    image: nginx:alpine"
  echo "    container_name: ${SITENAME}_web"
  echo "    restart: unless-stopped"
  echo "    ports:"
  echo "      - \"127.0.0.1:${HTTPPORT}:80\""
  echo "    volumes:"
  echo "      - ./html:/usr/share/nginx/html:ro"
  echo "      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro"
} > "$COMPOSE_FILE"

if [[ -n "$DB_TYPE" ]]; then
  echo "    depends_on:" >> "$COMPOSE_FILE"
  echo "      - db" >> "$COMPOSE_FILE"
  echo "" >> "$COMPOSE_FILE"
  echo "  db:" >> "$COMPOSE_FILE"

  case "$DB_TYPE" in
    mysql)
      cat >> "$COMPOSE_FILE" <<EOF
    image: mysql:8
    container_name: ${SITENAME}_db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASS}"
      MYSQL_DATABASE: "${DB_NAME}"
      MYSQL_USER: "${DB_USER}"
      MYSQL_PASSWORD: "${DB_PASS}"
    volumes:
      - ./db_data:/var/lib/mysql
EOF
      ;;
    mariadb)
      cat >> "$COMPOSE_FILE" <<EOF
    image: mariadb:11
    container_name: ${SITENAME}_db
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: "${DB_ROOT_PASS}"
      MARIADB_DATABASE: "${DB_NAME}"
      MARIADB_USER: "${DB_USER}"
      MARIADB_PASSWORD: "${DB_PASS}"
    volumes:
      - ./db_data:/var/lib/mysql
EOF
      ;;
    postgres)
      cat >> "$COMPOSE_FILE" <<EOF
    image: postgres:16-alpine
    container_name: ${SITENAME}_db
    restart: unless-stopped
    environment:
      POSTGRES_DB: "${DB_NAME}"
      POSTGRES_USER: "${DB_USER}"
      POSTGRES_PASSWORD: "${DB_PASS}"
    volumes:
      - ./db_data:/var/lib/postgresql/data
EOF
      ;;
    mongo)
      cat >> "$COMPOSE_FILE" <<EOF
    image: mongo:7
    container_name: ${SITENAME}_db
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: "${DB_USER}"
      MONGO_INITDB_ROOT_PASSWORD: "${DB_PASS}"
      MONGO_INITDB_DATABASE: "${DB_NAME}"
    volumes:
      - ./db_data:/data/db
EOF
      ;;
  esac

  # Guardar credenciales en un archivo con permisos restringidos
  CRED_FILE="${SITE_DIR}/db_credentials.txt"
  {
    echo "Motor:        ${DB_TYPE}"
    echo "Base:         ${DB_NAME}"
    echo "Usuario:      ${DB_USER}"
    echo "Password:     ${DB_PASS}"
    [[ -n "$DB_ROOT_PASS" ]] && echo "Root password: ${DB_ROOT_PASS}"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
fi

# ---------- Levantar contenedores ----------
info "Levantando contenedores con docker compose..."
(cd "$SITE_DIR" && docker compose up -d)
ok "Contenedores levantados."

# ---------- Configuración del servicio oculto de Tor ----------
TORRC="/etc/tor/torrc"
HS_DIR="/var/lib/tor/${SITENAME}/"

if ! grep -q "HiddenServiceDir ${HS_DIR}" "$TORRC" 2>/dev/null; then
  info "Agregando servicio oculto a ${TORRC}..."
  {
    echo ""
    echo "# --- Servicio oculto para ${SITENAME} ---"
    echo "HiddenServiceDir ${HS_DIR}"
    echo "HiddenServicePort 80 127.0.0.1:${HTTPPORT}"
  } >> "$TORRC"
fi

info "Reiniciando Tor..."
systemctl enable tor >/dev/null 2>&1 || true
systemctl restart tor

# ---------- Esperar el hostname .onion ----------
info "Esperando que Tor genere el hostname .onion..."
HOSTNAME_FILE="${HS_DIR}hostname"
TRIES=0
while [[ ! -f "$HOSTNAME_FILE" && $TRIES -lt 30 ]]; do
  sleep 1
  TRIES=$((TRIES+1))
done

if [[ ! -f "$HOSTNAME_FILE" ]]; then
  err "No se pudo generar el hostname .onion. Revisá 'journalctl -u tor' para más detalles."
  exit 1
fi

ONION_ADDRESS=$(cat "$HOSTNAME_FILE")

# ---------- Resumen final ----------
echo
echo "=================================================================="
ok "¡Listo! El sitio se está sirviendo correctamente."
echo "=================================================================="
echo "  Carpeta de archivos:   ${SITE_DIR}"
echo "  Página web (html):     ${SITE_DIR}/html"
echo "  docker-compose.yml:    ${COMPOSE_FILE}"
if [[ -n "$DB_TYPE" ]]; then
  echo "  Credenciales de DB:     ${SITE_DIR}/db_credentials.txt"
fi
echo "  Puerto local (no expuesto a internet): 127.0.0.1:${HTTPPORT}"
echo
echo "  Dirección .onion:      http://${ONION_ADDRESS}"
echo "=================================================================="
echo
warn "Recordá: el puerto ${HTTPPORT} solo escucha en 127.0.0.1 (localhost),"
warn "por lo que el sitio NO es accesible desde la red normal, solo vía Tor."
