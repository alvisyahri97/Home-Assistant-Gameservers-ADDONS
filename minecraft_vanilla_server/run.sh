#!/usr/bin/env bash
set -euo pipefail

RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "-----------------------------------------------------------"
echo " Minecraft Bedrock Dedicated Server (Home Assistant Add-on)"
echo "-----------------------------------------------------------"

# -----------------------------------------------------------
# Optionen / Configuration UI
# -----------------------------------------------------------
DATA_DIR="$(jq -r '.data_dir' /data/options.json 2>/dev/null || echo '/share/minecraft-bedrock')"
[[ "${DATA_DIR}" == "null" || -z "${DATA_DIR}" ]] && DATA_DIR="/share/minecraft-bedrock"

SERVER_NAME="$(jq -r '.server_name' /data/options.json 2>/dev/null || echo 'HA Bedrock Server')"
[[ "${SERVER_NAME}" == "null" ]] && SERVER_NAME="HA Bedrock Server"

GAMEMODE="$(jq -r '.gamemode' /data/options.json 2>/dev/null || echo 'survival')"
[[ "${GAMEMODE}" == "null" ]] && GAMEMODE="survival"

DIFFICULTY="$(jq -r '.difficulty' /data/options.json 2>/dev/null || echo 'easy')"
[[ "${DIFFICULTY}" == "null" ]] && DIFFICULTY="easy"

MAX_PLAYERS="$(jq -r '.max_players' /data/options.json 2>/dev/null || echo '10')"
[[ "${MAX_PLAYERS}" == "null" ]] && MAX_PLAYERS="10"

PORT_V6="$(jq -r '.server_portv6' /data/options.json 2>/dev/null || echo '19133')"
[[ "${PORT_V6}" == "null" ]] && PORT_V6="19133"

ALLOW_LIST="$(jq -r '.allow_list' /data/options.json 2>/dev/null || echo 'false')"
[[ "${ALLOW_LIST}" == "null" ]] && ALLOW_LIST="false"

CONTAINER_PORT="19132"

mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"

LOG_DIR="${DATA_DIR}/logs"
LOG_FILE="${LOG_DIR}/ha_console.log"
mkdir -p "${LOG_DIR}"

# -----------------------------------------------------------
# Bedrock Server-ZIP über offizielle API ermitteln 
# -----------------------------------------------------------
BEDROCK_ZIP="bedrock_server.zip"
URL_MARKER=".bedrock_url.txt"

get_latest_bedrock_url() {
  # Use the official JSON API to bypass HTML changes
  # Forced HTTP/1.1 and User-Agent to prevent Azure HTTP/2 errors
  curl -sL --http1.1 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links" | \
  jq -r '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl'
}

# The '|| true' prevents the script from silently crashing if a network error occurs
DOWNLOAD_URL="$(get_latest_bedrock_url || true)"

if [[ -z "${DOWNLOAD_URL}" || "${DOWNLOAD_URL}" == "null" ]]; then
  log_error "Konnte die Download-URL für den Bedrock-Server nicht ermitteln."
  exit 1
fi

# Download & extract if it's a new installation or a new version is found
if [[ ! -f "${BEDROCK_ZIP}" || ! -f "${URL_MARKER}" || "$(cat "${URL_MARKER}")" != "${DOWNLOAD_URL}" ]]; then
  log_info "Lade Bedrock Server herunter: ${DOWNLOAD_URL}"
  # Forced HTTP/1.1 and User-Agent to prevent Azure HTTP/2 stream drops
  curl -fL --http1.1 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --retry 3 --retry-delay 2 "${DOWNLOAD_URL}" -o "${BEDROCK_ZIP}"
  
  log_info "Entpacke Server-Dateien..."
  unzip -o "${BEDROCK_ZIP}" -x "server.properties" "permissions.json" "allowlist.json" "valid_known_packs.json" > /dev/null 2>&1 || true
  
  # If config files don't exist yet (first run), extract them specifically
  if [[ ! -f "server.properties" ]]; then
     unzip -o "${BEDROCK_ZIP}" "server.properties" "permissions.json" "allowlist.json" "valid_known_packs.json" > /dev/null 2>&1 || true
  fi

  echo "${DOWNLOAD_URL}" > "${URL_MARKER}"
  chmod +x bedrock_server
fi

# -----------------------------------------------------------
# server.properties – Einstellungen anwenden
# -----------------------------------------------------------
if [[ -f "./server.properties" ]]; then
  # Apply Port settings (Fixing the IPv6 crash)
  sed -i "s/^server-port=.*/server-port=${CONTAINER_PORT}/" ./server.properties || true
  sed -i "s/^server-portv6=.*/server-portv6=${PORT_V6}/" ./server.properties || true
  
  # Apply Home Assistant UI settings
  sed -i "s/^server-name=.*/server-name=\"${SERVER_NAME}\"/" ./server.properties || true
  sed -i "s/^gamemode=.*/gamemode=${GAMEMODE}/" ./server.properties || true
  sed -i "s/^difficulty=.*/difficulty=${DIFFICULTY}/" ./server.properties || true
  sed -i "s/^max-players=.*/max-players=${MAX_PLAYERS}/" ./server.properties || true
  sed -i "s/^allow-list=.*/allow-list=${ALLOW_LIST}/" ./server.properties || true
fi

# -----------------------------------------------------------
# Start
# -----------------------------------------------------------
log_info "Starte Minecraft Bedrock Server"
log_info "Server Name     : ${SERVER_NAME}"
log_info "Mode/Difficulty : ${GAMEMODE} / ${DIFFICULTY}"
log_info "Allow List      : ${ALLOW_LIST}"
log_info "Port (IPv4)     : ${CONTAINER_PORT} (UDP)"
log_info "Port (IPv6)     : ${PORT_V6} (UDP)"
log_info "Datenverzeichnis: ${DATA_DIR}"
log_info "Logdatei        : ${LOG_FILE}"
echo "-----------------------------------------------------------"

{
  echo ""
  echo "==================== $(date -Iseconds) ===================="
  echo "Minecraft Bedrock | IPv4: ${CONTAINER_PORT} | IPv6: ${PORT_V6}"
  echo "==========================================================="
} >> "${LOG_FILE}"

export LD_LIBRARY_PATH=.
exec ./bedrock_server 2>&1 | tee -a "${LOG_FILE}"
