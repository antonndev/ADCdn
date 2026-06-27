#!/usr/bin/env bash

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  MAGENTA='\033[1;35m'
  BLUE='\033[0;34m'
  WHITE='\033[1;37m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  MAGENTA=''
  BLUE=''
  WHITE=''
  BOLD=''
  DIM=''
  NC=''
fi

UI_RULE="======================================================================"
UI_SUBRULE="----------------------------------------------------------------------"

ui_rule() {
  local color="${1:-$DIM}"
  printf "%b%s%b\n" "${color}" "${UI_RULE}" "${NC}"
}

ui_subrule() {
  local color="${1:-$DIM}"
  printf "%b%s%b\n" "${color}" "${UI_SUBRULE}" "${NC}"
}

ui_banner() {
  printf '\n'
  ui_rule "${MAGENTA}${BOLD}"
  printf "%b%s%b\n" "${CYAN}${BOLD}" " ADPanel Initializer " "${NC}"
  ui_rule "${MAGENTA}${BOLD}"
  printf '\n'
}

ui_section() {
  printf '\n'
  ui_subrule "${BLUE}${DIM}"
  printf "%b%s%b\n" "${CYAN}${BOLD}" "$1" "${NC}"
  ui_subrule "${BLUE}${DIM}"
}

ui_info() {
  printf "%b%s%b\n" "${CYAN}${BOLD}" "$1" "${NC}"
}

ui_success() {
  printf "%b%s%b\n" "${GREEN}${BOLD}" "$1" "${NC}"
}

ui_warn() {
  printf "%b%s%b\n" "${YELLOW}${BOLD}" "$1" "${NC}"
}

ui_error() {
  printf "%b%s%b\n" "${RED}${BOLD}" "$1" "${NC}"
}

ui_menu_item() {
  printf "  %b%s%b\n" "${WHITE}${BOLD}" "$1" "${NC}"
}

ui_kv() {
  printf "%b%s%b %s\n" "${CYAN}${BOLD}" "$1" "${NC}" "$2"
}

ui_prompt() {
  printf "%b%s%b" "${MAGENTA}${BOLD}" "$1" "${NC}"
}

SUDO=""
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADPANEL_PRODUCTION_ROOT="${ADPANEL_PRODUCTION_ROOT:-/var/www/adpanel}"
PANEL_ROOT="${ADPANEL_PANEL_ROOT:-${PANEL_DIR:-}}"
if [ -z "$PANEL_ROOT" ]; then
  if [ -f "${ADPANEL_PRODUCTION_ROOT}/initialize.sh" ] && [ -f "${ADPANEL_PRODUCTION_ROOT}/index.js" ]; then
    PANEL_ROOT="$ADPANEL_PRODUCTION_ROOT"
  else
    PANEL_ROOT="$SCRIPT_DIR"
  fi
fi
if ! PANEL_ROOT="$(cd "$PANEL_ROOT" 2>/dev/null && pwd)"; then
  ui_error "Panel root not found: ${ADPANEL_PANEL_ROOT:-${PANEL_DIR:-$ADPANEL_PRODUCTION_ROOT}}"
  exit 1
fi
cd "$PANEL_ROOT" || exit 1

ui_banner
ui_section "Choose an option:"
ui_menu_item "1) Initialize Panel"
ui_menu_item "2) Change an user password"
ui_menu_item "3) Delete an user"
ui_menu_item "4) Create User"
ui_menu_item "5) Uninstall ADPanel"

CHOICE="${ADPANEL_INIT_CHOICE:-}"
if [ -z "$CHOICE" ] && [ "${1:-}" == "--uninstall" ]; then
  CHOICE="5"
elif [ -z "$CHOICE" ] && { [ "${1:-}" == "--sshterm-only" ] || [ "${1:-}" == "--repair-sshterm" ]; }; then
  CHOICE="6"
elif [ -z "$CHOICE" ] && [ "${1:-}" == "--repair-mysql" ]; then
  CHOICE="7"
elif [ -z "$CHOICE" ] && [ "${1:-}" == "--choice" ]; then
  CHOICE="${2:-}"
elif [ -z "$CHOICE" ] && [[ "${1:-}" == --choice=* ]]; then
  CHOICE="${1#--choice=}"
fi

if [ -n "$CHOICE" ]; then
  ui_info "Auto-selected option: ${CHOICE}"
else
  read -p "$(ui_prompt "Enter choice (1, 2, 3, 4 or 5): ")" CHOICE
fi
ui_kv "Panel root:" "$PANEL_ROOT"

CREATE_USER_SCRIPT=""
if [ -f "${PANEL_ROOT}/scripts/create-user.js" ]; then
  CREATE_USER_SCRIPT="${PANEL_ROOT}/scripts/create-user.js"
elif [ -f "${PANEL_ROOT}/create-user.js" ]; then
  CREATE_USER_SCRIPT="${PANEL_ROOT}/create-user.js"
fi

OS_ID="unknown"
OS_LIKE=""
OS_VERSION_ID=""
OS_MAJOR_ID=""
PKG_MGR="unknown"
INIT_SYSTEM="unknown"
PKG_METADATA_READY="false"
PLATFORM_SUMMARY_SHOWN="false"
RHEL_EXTRA_REPOS_READY="false"

REDIS_SERVER_CMD="redis-server"
REDIS_CLI_CMD="redis-cli"
NODE_MIN_MAJOR=18
GO_MIN_VERSION="1.24.0"
GO_INSTALL_VERSION="1.24.11"
ADPANEL_SOURCE_RAW_BASE="${ADPANEL_SOURCE_RAW_BASE:-https://raw.githubusercontent.com/antonndev/ADPanel/main}"

MYSQL_HOST=""
MYSQL_PORT=""
MYSQL_USER=""
MYSQL_PASSWORD=""
MYSQL_DATABASE=""
MYSQL_URL=""

ADMIN_DEFAULT_AVATAR="https://cdn.jsdelivr.net/gh/antonndev/ADCDn/admin-avatar.webp"
NORMAL_DEFAULT_AVATARS=(
  "https://cdn.jsdelivr.net/gh/antonndev/ADCDn/normal-1.webp"
  "https://cdn.jsdelivr.net/gh/antonndev/ADCDn/normal-2.webp"
  "https://cdn.jsdelivr.net/gh/antonndev/ADCDn/normal-3.webp"
)

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

trim_ws() {
  printf "%s" "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

lower_trim() {
  trim_ws "$1" | tr '[:upper:]' '[:lower:]'
}

run_with_retries() {
  local attempts="${ADPANEL_RETRY_ATTEMPTS:-3}"
  local delay="${ADPANEL_RETRY_DELAY:-5}"
  local attempt=1
  local rc=0

  while [ "$attempt" -le "$attempts" ]; do
    if "$@"; then
      return 0
    fi
    rc=$?
    if [ "$attempt" -lt "$attempts" ]; then
      ui_warn "Command failed (attempt ${attempt}/${attempts}); retrying in ${delay}s..."
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  return "$rc"
}

apt_root() {
  $SUDO env \
    DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE=a \
    APT_LISTCHANGES_FRONTEND=none \
    "$@"
}

apt_repair_state() {
  [ "$PKG_MGR" = "apt" ] || return 0
  apt_root dpkg --configure -a >/dev/null 2>&1 || true
  apt_root apt-get -y \
    -o Dpkg::Use-Pty=0 \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -o Acquire::Retries=3 \
    -f install >/dev/null 2>&1 || true
}

systemd_available() {
  cmd_exists systemctl || return 1
  [ -d /run/systemd/system ] || return 1
  systemctl list-units >/dev/null 2>&1
}

pick_default_avatar_url() {
  local role="${1:-user}"
  if [ "$role" = "admin" ]; then
    printf "%s" "$ADMIN_DEFAULT_AVATAR"
    return 0
  fi

  local index=0
  if [ "${#NORMAL_DEFAULT_AVATARS[@]}" -gt 1 ]; then
    index=$((RANDOM % ${#NORMAL_DEFAULT_AVATARS[@]}))
  fi

  printf "%s" "${NORMAL_DEFAULT_AVATARS[$index]}"
}

detect_platform() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_MAJOR_ID="${OS_VERSION_ID%%.*}"
  fi

  if systemd_available; then
    INIT_SYSTEM="systemd"
  elif cmd_exists rc-service; then
    INIT_SYSTEM="openrc"
  elif cmd_exists service; then
    INIT_SYSTEM="sysv"
  else
    INIT_SYSTEM="unknown"
  fi

  if cmd_exists apt-get; then
    PKG_MGR="apt"
  elif cmd_exists dnf; then
    PKG_MGR="dnf"
  elif cmd_exists yum; then
    PKG_MGR="yum"
  elif cmd_exists apk; then
    PKG_MGR="apk"
  elif cmd_exists pacman; then
    PKG_MGR="pacman"
  elif cmd_exists zypper; then
    PKG_MGR="zypper"
  else
    PKG_MGR="unknown"
  fi
}

platform_summary() {
  local summary="${OS_ID}"
  if [ -n "$OS_LIKE" ]; then
    summary="${summary} (like ${OS_LIKE})"
  fi
  printf "%s" "$summary"
}

log_platform_summary() {
  if [ "$PLATFORM_SUMMARY_SHOWN" = "true" ]; then
    return 0
  fi

  ui_info "Detected operating system and package manager:"
  ui_kv "  OS:" "$(platform_summary)"
  ui_kv "  Package manager:" "$PKG_MGR"
  ui_kv "  Init system:" "$INIT_SYSTEM"
  PLATFORM_SUMMARY_SHOWN="true"
}

detect_default_panel_ip() {
  local ip=""

  if cmd_exists curl; then
    ip=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || true)
    if [ -z "$ip" ]; then
      ip=$(curl -4 -s --max-time 3 icanhazip.com 2>/dev/null || true)
    fi
  fi

  if [ -z "$ip" ] && cmd_exists hostname; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi

  if [ -z "$ip" ] && cmd_exists ip; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)
  fi

  if [ -z "$ip" ] && cmd_exists ifconfig; then
    ip=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}' | sed 's/^addr://' || true)
  fi

  if [ -z "$ip" ]; then
    ip="127.0.0.1"
  fi

  printf "%s" "$ip"
}

normalize_port() {
  local value
  value="$(trim_ws "${1:-}")"
  local fallback="${2:-}"
  if printf "%s" "$value" | grep -qE '^[0-9]+$' && [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null; then
    printf "%s" "$value"
  else
    printf "%s" "$fallback"
  fi
}

build_public_url() {
  local scheme="$1"
  local host="$2"
  local port="$3"
  local default_port="80"
  local port_segment=""

  if [ "$scheme" = "https" ]; then
    default_port="443"
  fi

  if [ -n "$port" ] && [ "$port" != "$default_port" ]; then
    port_segment=":${port}"
  fi

  printf "%s://%s%s" "$scheme" "$host" "$port_segment"
}

require_sudo_if_needed() {
  if [ "$EUID" -ne 0 ] && ! cmd_exists sudo; then
    ui_error "sudo is required when running this script as a non-root user."
    exit 1
  fi
}

python_ready() {
  cmd_exists python3 || cmd_exists python
}

ensure_python_binary_alias() {
  if cmd_exists python3; then
    return 0
  fi

  if ! cmd_exists python; then
    return 1
  fi

  local python_bin
  python_bin="$(command -v python 2>/dev/null || true)"
  if [ -z "$python_bin" ]; then
    return 1
  fi

  if [ "$EUID" -eq 0 ] || [ -n "$SUDO" ]; then
    $SUDO mkdir -p /usr/local/bin >/dev/null 2>&1 || true
    $SUDO ln -sf "$python_bin" /usr/local/bin/python3 >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
  fi

  python_ready
}

ensure_supported_package_manager() {
  if [ "$PKG_MGR" != "unknown" ]; then
    return 0
  fi

  ui_error "Could not detect a supported package manager on this system."
  return 1
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      apt_repair_state
      run_with_retries apt_root apt-get -y \
        -o Dpkg::Use-Pty=0 \
        -o DPkg::Lock::Timeout=300 \
        -o Acquire::Retries=3 \
        update
      ;;
    dnf)
      $SUDO dnf -y --setopt=timeout=60 makecache || $SUDO dnf -y --setopt=timeout=60 check-update || true
      ;;
    yum)
      $SUDO yum -y makecache || $SUDO yum -y check-update || true
      ;;
    apk)
      run_with_retries $SUDO apk update
      ;;
    pacman)
      run_with_retries $SUDO pacman -Sy --noconfirm
      ;;
    zypper)
      run_with_retries $SUDO zypper --non-interactive --gpg-auto-import-keys refresh
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_pkg_metadata() {
  if [ "$PKG_METADATA_READY" = "true" ]; then
    return 0
  fi

  if ! ensure_supported_package_manager; then
    return 1
  fi

  ui_info "Refreshing package metadata for ${PKG_MGR}..."
  if pkg_update; then
    PKG_METADATA_READY="true"
    return 0
  fi

  ui_warn "Package metadata refresh failed; continuing with the existing cache."
  return 0
}

pkg_install() {
  case "$PKG_MGR" in
    apt)
      apt_repair_state
      run_with_retries apt_root apt-get install -y \
        -o Dpkg::Use-Pty=0 \
        -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        -o Acquire::Retries=3 \
        "$@"
      ;;
    dnf)
      run_with_retries $SUDO dnf install -y --setopt=timeout=60 "$@"
      ;;
    yum)
      run_with_retries $SUDO yum install -y "$@"
      ;;
    apk)
      run_with_retries $SUDO apk add --no-cache "$@"
      ;;
    pacman)
      run_with_retries $SUDO pacman -S --noconfirm --needed "$@"
      ;;
    zypper)
      run_with_retries $SUDO zypper --non-interactive --gpg-auto-import-keys in -l --auto-agree-with-licenses "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

enable_rhel_extra_repos() {
  [ "$RHEL_EXTRA_REPOS_READY" = "true" ] && return 0
  RHEL_EXTRA_REPOS_READY="true"

  case "$PKG_MGR" in
    dnf|yum) ;;
    *) return 0 ;;
  esac

  case "$OS_ID" in
    fedora)
      return 0
      ;;
  esac

  ui_info "Checking optional RHEL-compatible repositories..."
  if [ "$PKG_MGR" = "dnf" ]; then
    $SUDO dnf install -y --setopt=timeout=60 dnf-plugins-core >/dev/null 2>&1 || true
    $SUDO dnf install -y --setopt=timeout=60 epel-release >/dev/null 2>&1 || true
    if cmd_exists crb; then
      $SUDO crb enable >/dev/null 2>&1 || true
    fi
    $SUDO dnf config-manager --set-enabled crb >/dev/null 2>&1 || \
      $SUDO dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
  else
    $SUDO yum install -y epel-release >/dev/null 2>&1 || true
    if cmd_exists yum-config-manager; then
      $SUDO yum-config-manager --enable crb >/dev/null 2>&1 || \
        $SUDO yum-config-manager --enable powertools >/dev/null 2>&1 || true
    fi
  fi

  PKG_METADATA_READY="false"
  return 0
}

enable_rhel_redis_module_if_available() {
  case "$PKG_MGR" in
    dnf|yum) ;;
    *) return 0 ;;
  esac

  local module_cmd="$PKG_MGR"
  local tmp=""
  tmp="$(mktemp /tmp/adpanel-redis-module.XXXXXX 2>/dev/null || echo "")"
  [ -n "$tmp" ] || return 0

  if ! $SUDO "$module_cmd" -q module list redis >"$tmp" 2>/dev/null; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  local stream=""
  for candidate in 7 6 5; do
    if grep -Eq "^[[:space:]]*redis[[:space:]]+${candidate}([[:space:]]|$|\\[)" "$tmp"; then
      stream="$candidate"
      break
    fi
  done
  rm -f "$tmp" >/dev/null 2>&1 || true

  [ -n "$stream" ] || return 0
  ui_info "Enabling Redis module stream redis:${stream}..."
  $SUDO "$module_cmd" -y module reset redis >/dev/null 2>&1 || true
  $SUDO "$module_cmd" -y module enable "redis:${stream}" >/dev/null 2>&1 || true
  PKG_METADATA_READY="false"
  return 0
}

supports_official_redis_rpm_repo() {
  case "$PKG_MGR" in
    dnf|yum) ;;
    *) return 1 ;;
  esac

  case "$OS_MAJOR_ID" in
    8|9) ;;
    *) return 1 ;;
  esac

  case "$OS_ID" in
    rocky|rockylinux|almalinux|alma|centos|rhel|ol|oracle)
      return 0
      ;;
  esac

  printf "%s" "$OS_LIKE" | grep -qiE '(^|[[:space:]])(rhel|fedora)([[:space:]]|$)'
}

install_redis_from_official_rpm_repo() {
  supports_official_redis_rpm_repo || return 1
  cmd_exists rpm || return 1

  local repo_major="$OS_MAJOR_ID"
  local repo_file="/etc/yum.repos.d/redis.repo"
  local key_file="/tmp/adpanel-redis.key"
  local baseurl="${ADPANEL_REDIS_RPM_REPO_BASEURL:-http://packages.redis.io/rpm/rockylinux${repo_major}}"

  ui_info "Trying official Redis RPM repository for RHEL-compatible ${repo_major}..."
  if download_file "https://packages.redis.io/gpg" "$key_file" >/dev/null 2>&1; then
    $SUDO rpm --import "$key_file" >/dev/null 2>&1 || true
    rm -f "$key_file" >/dev/null 2>&1 || true
  else
    ui_warn "Could not download Redis GPG key; skipping official Redis RPM fallback."
    return 1
  fi

  $SUDO mkdir -p /etc/yum.repos.d >/dev/null 2>&1 || true
  cat <<EOF | $SUDO tee "$repo_file" >/dev/null
[Redis]
name=Redis
baseurl=${baseurl}
enabled=1
gpgcheck=1
gpgkey=https://packages.redis.io/gpg
EOF

  $SUDO "$PKG_MGR" -y module reset redis >/dev/null 2>&1 || true
  $SUDO "$PKG_MGR" -y module disable redis >/dev/null 2>&1 || true
  PKG_METADATA_READY="false"
  ensure_pkg_metadata >/dev/null 2>&1 || true

  pkg_install redis
}

pkg_install_try_sets() {
  local set
  for set in "$@"; do
    if pkg_install $set >/dev/null 2>&1; then
      return 0
    fi
  done
  set="${*: -1}"
  pkg_install $set
}

install_node_runtime_packages() {
  case "$PKG_MGR" in
    apt|apk|pacman)
      pkg_install_try_sets \
        "nodejs npm"
      ;;
    dnf|yum)
      pkg_install_try_sets \
        "nodejs npm" \
        "nodejs nodejs-npm" \
        "nodejs22 npm" \
        "nodejs22 nodejs22-npm" \
        "nodejs22 nodejs-npm" \
        "nodejs20 npm" \
        "nodejs20 nodejs20-npm" \
        "nodejs20 nodejs-npm" \
        "nodejs18 npm" \
        "nodejs18 nodejs18-npm" \
        "nodejs18 nodejs-npm" \
        "nodejs"
      ;;
    zypper)
      pkg_install_try_sets \
        "nodejs npm" \
        "nodejs22 npm22" \
        "nodejs20 npm20" \
        "nodejs18 npm18" \
        "nodejs16 npm16" \
        "nodejs22" \
        "nodejs20" \
        "nodejs18" \
        "nodejs16" \
        "nodejs"
      ;;
    *)
      return 1
      ;;
  esac
}

install_npm_package_only() {
  case "$PKG_MGR" in
    apt|apk|pacman)
      pkg_install npm
      ;;
    dnf|yum)
      pkg_install_try_sets \
        "npm" \
        "nodejs22-npm" \
        "nodejs20-npm" \
        "nodejs18-npm" \
        "nodejs-npm"
      ;;
    zypper)
      pkg_install_try_sets \
        "npm" \
        "npm22" \
        "npm20" \
        "npm18" \
        "npm16"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_node_binary_alias() {
  if cmd_exists node; then
    return 0
  fi

  if ! cmd_exists nodejs; then
    return 1
  fi

  local nodejs_bin
  nodejs_bin="$(command -v nodejs 2>/dev/null || true)"
  if [ -z "$nodejs_bin" ]; then
    return 1
  fi

  if [ "$EUID" -eq 0 ] || [ -n "$SUDO" ]; then
    $SUDO mkdir -p /usr/local/bin >/dev/null 2>&1 || true
    $SUDO ln -sf "$nodejs_bin" /usr/local/bin/node >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
  fi

  cmd_exists node
}

node_major_version() {
  if ! cmd_exists node; then
    echo 0
    return 0
  fi

  node -p "Number(process.versions.node.split('.')[0]) || 0" 2>/dev/null || echo 0
}

node_runtime_version_ok() {
  local major
  major="$(node_major_version)"
  [ "$major" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null
}

node_runtime_ready() {
  cmd_exists node && cmd_exists npm && node_runtime_version_ok
}

download_file() {
  local url="$1"
  local dest="$2"
  if cmd_exists curl; then
    run_with_retries curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 "$url" -o "$dest"
  elif cmd_exists wget; then
    run_with_retries wget -O "$dest" "$url"
  else
    return 1
  fi
}

is_musl_libc() {
  ldd --version 2>&1 | grep -qi musl
}

node_official_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7l" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    *)
      return 1
      ;;
  esac
}

install_official_node_runtime() {
  local arch=""
  local tmpdir=""
  local sums_url="https://nodejs.org/dist/latest-v20.x/SHASUMS256.txt"
  local tarball=""
  local expected=""
  local actual=""
  local node_dir=""

  arch="$(node_official_arch)" || {
    ui_warn "Official Node.js binary fallback does not support CPU architecture: $(uname -m)."
    return 1
  }

  if is_musl_libc; then
    ui_warn "Detected musl libc; using distribution Node.js packages instead of the official glibc Node.js binary."
    return 1
  fi

  if ! cmd_exists tar; then
    ui_warn "tar is required for the official Node.js binary fallback."
    return 1
  fi

  tmpdir="$(mktemp -d /tmp/adpanel-node.XXXXXX 2>/dev/null || mktemp -d)"
  if [ -z "$tmpdir" ]; then
    return 1
  fi

  ui_info "Trying official Node.js 20 LTS binary fallback..."
  if ! download_file "$sums_url" "${tmpdir}/SHASUMS256.txt"; then
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    return 1
  fi

  tarball="$(awk -v suffix="linux-${arch}.tar.xz" '$2 ~ suffix "$" {print $2; exit}' "${tmpdir}/SHASUMS256.txt")"
  if [ -z "$tarball" ]; then
    tarball="$(awk -v suffix="linux-${arch}.tar.gz" '$2 ~ suffix "$" {print $2; exit}' "${tmpdir}/SHASUMS256.txt")"
  fi
  if [ -z "$tarball" ]; then
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    return 1
  fi

  if ! download_file "https://nodejs.org/dist/latest-v20.x/${tarball}" "${tmpdir}/${tarball}"; then
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    return 1
  fi

  expected="$(awk -v file="$tarball" '$2 == file {print $1; exit}' "${tmpdir}/SHASUMS256.txt")"
  if [ -n "$expected" ] && cmd_exists sha256sum; then
    actual="$(sha256sum "${tmpdir}/${tarball}" | awk '{print $1}')"
    if [ "$expected" != "$actual" ]; then
      ui_warn "Node.js binary checksum mismatch."
      rm -rf "$tmpdir" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  node_dir="${tarball%.tar.xz}"
  node_dir="${node_dir%.tar.gz}"

  $SUDO mkdir -p /usr/local/lib/nodejs
  case "$tarball" in
    *.tar.xz) $SUDO tar -C /usr/local/lib/nodejs -xJf "${tmpdir}/${tarball}" ;;
    *.tar.gz) $SUDO tar -C /usr/local/lib/nodejs -xzf "${tmpdir}/${tarball}" ;;
    *)
      rm -rf "$tmpdir" >/dev/null 2>&1 || true
      return 1
      ;;
  esac

  $SUDO ln -sf "/usr/local/lib/nodejs/${node_dir}/bin/node" /usr/local/bin/node
  $SUDO ln -sf "/usr/local/lib/nodejs/${node_dir}/bin/npm" /usr/local/bin/npm
  $SUDO ln -sf "/usr/local/lib/nodejs/${node_dir}/bin/npx" /usr/local/bin/npx
  if [ -x "/usr/local/lib/nodejs/${node_dir}/bin/corepack" ]; then
    $SUDO ln -sf "/usr/local/lib/nodejs/${node_dir}/bin/corepack" /usr/local/bin/corepack
  fi

  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  node_runtime_ready
}

install_modern_node_runtime() {
  case "$PKG_MGR" in
    apt)
      if cmd_exists curl; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash - || return 1
        PKG_METADATA_READY="false"
        ensure_pkg_metadata >/dev/null 2>&1 || true
        pkg_install nodejs
        return $?
      fi
      ;;
    dnf|yum)
      if cmd_exists curl; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | $SUDO bash - || return 1
        PKG_METADATA_READY="false"
        ensure_pkg_metadata >/dev/null 2>&1 || true
        pkg_install nodejs
        return $?
      fi
      ;;
    zypper)
      pkg_install_try_sets \
        "nodejs22 npm22" \
        "nodejs20 npm20" \
        "nodejs18 npm18" \
        "nodejs22" \
        "nodejs20" \
        "nodejs18"
      return $?
      ;;
    apk|pacman)
      install_node_runtime_packages
      return $?
      ;;
  esac

  return 1
}

compiler_ready() {
  cmd_exists gcc || cmd_exists cc || cmd_exists clang
}

cpp_compiler_ready() {
  cmd_exists g++ || cmd_exists c++ || cmd_exists clang++
}

install_base_system_packages() {
  local need_base="false"

  if ! cmd_exists curl || ! cmd_exists openssl || ! cmd_exists tar || ! cmd_exists xz || ! python_ready || ! cmd_exists make || ! cmd_exists git; then
    need_base="true"
  fi
  if ! compiler_ready || ! cpp_compiler_ready; then
    need_base="true"
  fi

  if [ "$need_base" != "true" ]; then
    ui_success "Base system packages are already installed."
    return 0
  fi

  if ! ensure_supported_package_manager; then
    return 1
  fi

  log_platform_summary
  ui_info "Installing base system packages for ${OS_ID}..."
  ensure_pkg_metadata >/dev/null 2>&1 || true

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git openssl tar xz-utils python3 make g++
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git openssl tar xz python3 make gcc gcc-c++
      ;;
    apk)
      pkg_install ca-certificates curl git openssl tar xz python3 make g++
      ;;
    pacman)
      pkg_install ca-certificates curl git openssl tar xz python make gcc
      ;;
    zypper)
      pkg_install ca-certificates curl git openssl tar xz python3 make gcc-c++
      ;;
    *)
      ui_error "Unsupported package manager for base system packages."
      return 1
      ;;
  esac

  if cmd_exists update-ca-certificates; then
    $SUDO update-ca-certificates >/dev/null 2>&1 || true
  fi
  ensure_python_binary_alias >/dev/null 2>&1 || true

  if ! cmd_exists curl || ! cmd_exists openssl || ! cmd_exists tar || ! cmd_exists xz || ! python_ready || ! cmd_exists make || ! cmd_exists git; then
    ui_error "Failed to install one or more required base system packages."
    return 1
  fi
  if ! compiler_ready || ! cpp_compiler_ready; then
    ui_error "A C/C++ compiler is still missing after package installation."
    return 1
  fi

  ui_success "Base system packages installed successfully."
  return 0
}

ensure_node_runtime() {
  if ! cmd_exists node; then
    ensure_node_binary_alias >/dev/null 2>&1 || true
  fi

  if node_runtime_ready; then
    ui_success "Node.js and npm are already installed."
    ui_kv "  node:" "$(node -v 2>/dev/null)"
    ui_kv "  npm:" "$(npm -v 2>/dev/null)"
    return 0
  fi

  if cmd_exists node && ! node_runtime_version_ok; then
    ui_warn "Installed Node.js is too old ($(node -v 2>/dev/null)); Node.js ${NODE_MIN_MAJOR}+ is required."
  fi

  if ! ensure_supported_package_manager; then
    return 1
  fi

  log_platform_summary
  ui_info "Installing Node.js and npm..."
  ensure_pkg_metadata >/dev/null 2>&1 || true

  if { ! cmd_exists node || ! cmd_exists npm || ! node_runtime_version_ok; } && install_modern_node_runtime; then
    ensure_node_binary_alias >/dev/null 2>&1 || true
  fi

  if { ! cmd_exists node || ! cmd_exists npm || ! node_runtime_version_ok; } && install_official_node_runtime; then
    ensure_node_binary_alias >/dev/null 2>&1 || true
  fi

  if { ! cmd_exists node || ! cmd_exists npm; } && ! install_node_runtime_packages; then
    ui_warn "Combined Node.js/npm package installation failed; trying a smaller npm-only fallback if possible..."
  fi

  if ! cmd_exists npm && ! install_npm_package_only; then
    ui_warn "Separate npm package installation failed; checking if npm shipped with Node.js..."
  fi

  ensure_node_binary_alias >/dev/null 2>&1 || true

  if { ! cmd_exists node || ! cmd_exists npm || ! node_runtime_version_ok; } && install_modern_node_runtime; then
    ensure_node_binary_alias >/dev/null 2>&1 || true
  fi

  if { ! cmd_exists node || ! cmd_exists npm || ! node_runtime_version_ok; } && install_official_node_runtime; then
    ensure_node_binary_alias >/dev/null 2>&1 || true
  fi

  if ! cmd_exists node || ! cmd_exists npm; then
    ui_error "Node.js and npm are required but could not be installed automatically."
    return 1
  fi

  if ! node_runtime_version_ok; then
    ui_error "Node.js ${NODE_MIN_MAJOR}+ is required, but detected $(node -v 2>/dev/null)."
    ui_warn "Install Node.js 20 LTS manually and re-run initialization."
    return 1
  fi

  ui_success "Node.js and npm installed successfully."
  ui_kv "  node:" "$(node -v 2>/dev/null)"
  ui_kv "  npm:" "$(npm -v 2>/dev/null)"
  return 0
}

version_at_least() {
  local current="$1"
  local required="$2"
  local c_major=0 c_minor=0 c_patch=0 r_major=0 r_minor=0 r_patch=0

  current="${current#v}"
  current="${current#go}"
  required="${required#v}"
  required="${required#go}"
  current="${current%%[-+~]*}"
  required="${required%%[-+~]*}"

  IFS=. read -r c_major c_minor c_patch <<EOF
$current
EOF
  IFS=. read -r r_major r_minor r_patch <<EOF
$required
EOF

  c_major="${c_major:-0}"; c_minor="${c_minor:-0}"; c_patch="${c_patch:-0}"
  r_major="${r_major:-0}"; r_minor="${r_minor:-0}"; r_patch="${r_patch:-0}"

  [ "$c_major" -gt "$r_major" ] 2>/dev/null && return 0
  [ "$c_major" -lt "$r_major" ] 2>/dev/null && return 1
  [ "$c_minor" -gt "$r_minor" ] 2>/dev/null && return 0
  [ "$c_minor" -lt "$r_minor" ] 2>/dev/null && return 1
  [ "$c_patch" -ge "$r_patch" ] 2>/dev/null
}

go_version_value() {
  local current=""
  if ! cmd_exists go; then
    echo ""
    return 0
  fi

  current="$(go env GOVERSION 2>/dev/null || true)"
  if [ -z "$current" ]; then
    current="$(go version 2>/dev/null | awk '{print $3}' || true)"
  fi
  current="${current#go}"
  echo "$current"
}

go_runtime_ready() {
  local current
  current="$(go_version_value)"
  [ -n "$current" ] && version_at_least "$current" "$GO_MIN_VERSION"
}

go_official_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv6l|armv7l) echo "armv6l" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    *)
      return 1
      ;;
  esac
}

install_go_runtime_packages() {
  case "$PKG_MGR" in
    apt)
      pkg_install_try_sets "golang-go" "golang" "go"
      ;;
    dnf|yum)
      pkg_install_try_sets "golang" "go"
      ;;
    apk|pacman|zypper)
      pkg_install_try_sets "go" "golang"
      ;;
    *)
      return 1
      ;;
  esac
}

install_official_go_runtime() {
  local arch=""
  local tarball=""
  local tmpdir=""
  local url=""
  local alt_url=""

  arch="$(go_official_arch)" || {
    ui_warn "Official Go fallback does not support CPU architecture: $(uname -m)."
    return 1
  }

  tarball="go${GO_INSTALL_VERSION}.linux-${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  alt_url="https://dl.google.com/go/${tarball}"
  tmpdir="$(mktemp -d /tmp/adpanel-go.XXXXXX 2>/dev/null || mktemp -d)"
  if [ -z "$tmpdir" ]; then
    return 1
  fi

  ui_info "Installing official Go ${GO_INSTALL_VERSION} toolchain..."
  if ! download_file "$url" "${tmpdir}/${tarball}"; then
    if ! download_file "$alt_url" "${tmpdir}/${tarball}"; then
      rm -rf "$tmpdir" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  $SUDO rm -rf /usr/local/go
  if ! $SUDO tar -C /usr/local -xzf "${tmpdir}/${tarball}"; then
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    return 1
  fi

  $SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
  $SUDO ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  go_runtime_ready
}

ensure_go_runtime() {
  if go_runtime_ready; then
    ui_success "Go runtime is already installed."
    ui_kv "  go:" "$(go version 2>/dev/null)"
    return 0
  fi

  if ! ensure_supported_package_manager; then
    return 1
  fi

  log_platform_summary
  ui_info "Installing Go runtime for ADPanel SSH terminal..."
  ensure_pkg_metadata >/dev/null 2>&1 || true

  install_go_runtime_packages >/dev/null 2>&1 || true
  if ! go_runtime_ready; then
    install_official_go_runtime || true
  fi

  if go_runtime_ready; then
    ui_success "Go runtime installed successfully."
    ui_kv "  go:" "$(go version 2>/dev/null)"
    return 0
  fi

  ui_warn "Go ${GO_MIN_VERSION}+ could not be installed automatically; SSH terminal service will be skipped."
  return 1
}

project_extensions_ready() {
  [ -d "${PANEL_ROOT}/node_modules" ] || return 1

  npm ls --omit=dev --depth=0 >/dev/null 2>&1
}

install_project_extensions() {
  if ! ensure_node_runtime; then
    return 1
  fi

  if project_extensions_ready; then
    ui_success "Project extensions are already installed."
    return 0
  fi

  ui_info "Installing extensions..."
  if ! npm install --omit=dev --no-fund --no-audit; then
    ui_error "npm install failed."
    return 1
  fi

  if ! project_extensions_ready; then
    ui_error "Extensions were installed, but required Node modules are still missing."
    return 1
  fi

  ui_success "Project extensions installed successfully."
  return 0
}

ensure_node_prerequisites() {
  log_platform_summary

  if ! install_base_system_packages; then
    return 1
  fi

  if ! ensure_node_runtime; then
    return 1
  fi

  install_project_extensions
}

service_enable() {
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      $SUDO systemctl enable "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      $SUDO rc-update add "$svc" default >/dev/null 2>&1 || true
      ;;
    sysv)
      if cmd_exists update-rc.d; then
        $SUDO update-rc.d "$svc" defaults >/dev/null 2>&1 || true
      elif cmd_exists chkconfig; then
        $SUDO chkconfig "$svc" on >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

service_start() {
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      $SUDO systemctl start "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      $SUDO rc-service "$svc" start >/dev/null 2>&1 || true
      ;;
    sysv)
      $SUDO service "$svc" start >/dev/null 2>&1 || true
      ;;
  esac
}

service_stop() {
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      $SUDO systemctl stop "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      $SUDO rc-service "$svc" stop >/dev/null 2>&1 || true
      ;;
    sysv)
      $SUDO service "$svc" stop >/dev/null 2>&1 || true
      ;;
  esac
}

service_restart() {
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      $SUDO systemctl restart "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      $SUDO rc-service "$svc" restart >/dev/null 2>&1 || true
      ;;
    sysv)
      $SUDO service "$svc" restart >/dev/null 2>&1 || true
      ;;
  esac
}

service_reload() {
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      $SUDO systemctl reload "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      $SUDO rc-service "$svc" reload >/dev/null 2>&1 || service_restart "$svc"
      ;;
    sysv)
      $SUDO service "$svc" reload >/dev/null 2>&1 || service_restart "$svc"
      ;;
  esac
}

ensure_panel_env_permissions() {
  local panel_root="${1:-$PANEL_ROOT}"
  local env_file="${panel_root}/.env"
  [ -f "$env_file" ] || return 0

  if id -u adpanel >/dev/null 2>&1; then
    $SUDO chown adpanel:adpanel "$env_file" >/dev/null 2>&1 || true
    $SUDO chmod 0640 "$env_file" >/dev/null 2>&1 || true
  else
    $SUDO chmod 0600 "$env_file" >/dev/null 2>&1 || true
  fi
}

is_rhel_like_platform() {
  local id_like=" ${OS_LIKE:-} "
  case "${OS_ID:-}" in
    rocky|rhel|almalinux|centos|ol|fedora)
      return 0
      ;;
  esac
  case "$id_like" in
    *" rhel "*|*" fedora "*)
      return 0
      ;;
  esac
  return 1
}

apply_adpanel_host_limits() {
  local file_max="${ADPANEL_HOST_FILE_MAX:-1048576}"
  local nr_open="${ADPANEL_HOST_NR_OPEN:-1048576}"
  local inotify_watches="${ADPANEL_INOTIFY_MAX_USER_WATCHES:-1048576}"
  local inotify_instances="${ADPANEL_INOTIFY_MAX_USER_INSTANCES:-2048}"
  local sysctl_file="/etc/sysctl.d/99-adpanel-host-limits.conf"
  local limits_file="/etc/security/limits.d/99-adpanel-nofile.conf"

  if ! printf "%s" "$file_max" | grep -qE '^[0-9]+$'; then file_max=1048576; fi
  if ! printf "%s" "$nr_open" | grep -qE '^[0-9]+$'; then nr_open=1048576; fi
  if ! printf "%s" "$inotify_watches" | grep -qE '^[0-9]+$'; then inotify_watches=1048576; fi
  if ! printf "%s" "$inotify_instances" | grep -qE '^[0-9]+$'; then inotify_instances=2048; fi

  if [ "$file_max" -lt 1048576 ] 2>/dev/null; then file_max=1048576; fi
  if [ "$nr_open" -lt 1048576 ] 2>/dev/null; then nr_open=1048576; fi

  if is_rhel_like_platform; then
    ui_info "Applying Rocky/RHEL-safe host file limits for Docker game servers..."
  else
    ui_info "Applying ADPanel host file limits for Docker game servers..."
  fi

  cat <<EOF | $SUDO tee "$sysctl_file" >/dev/null
# Managed by ADPanel. Required for game servers that open many files/sockets.
fs.file-max = ${file_max}
fs.nr_open = ${nr_open}
fs.inotify.max_user_watches = ${inotify_watches}
fs.inotify.max_user_instances = ${inotify_instances}
EOF

  $SUDO sysctl -w "fs.file-max=${file_max}" >/dev/null 2>&1 || true
  $SUDO sysctl -w "fs.nr_open=${nr_open}" >/dev/null 2>&1 || true
  $SUDO sysctl -w "fs.inotify.max_user_watches=${inotify_watches}" >/dev/null 2>&1 || true
  $SUDO sysctl -w "fs.inotify.max_user_instances=${inotify_instances}" >/dev/null 2>&1 || true

  cat <<EOF | $SUDO tee "$limits_file" >/dev/null
# Managed by ADPanel.
* soft nofile ${nr_open}
* hard nofile ${nr_open}
root soft nofile ${nr_open}
root hard nofile ${nr_open}
adpanel soft nofile ${nr_open}
adpanel hard nofile ${nr_open}
adaemon soft nofile ${nr_open}
adaemon hard nofile ${nr_open}
EOF

  ui_success "Host file limits set to ${nr_open}."
}

detect_redis_commands() {
  if cmd_exists redis-server; then
    REDIS_SERVER_CMD="redis-server"
  elif cmd_exists valkey-server; then
    REDIS_SERVER_CMD="valkey-server"
  elif cmd_exists valkey; then
    REDIS_SERVER_CMD="valkey"
  fi

  if cmd_exists redis-cli; then
    REDIS_CLI_CMD="redis-cli"
  elif cmd_exists valkey-cli; then
    REDIS_CLI_CMD="valkey-cli"
  elif cmd_exists valkey; then
    REDIS_CLI_CMD="redis-cli"
  fi
}

detect_platform
require_sudo_if_needed
detect_redis_commands

setup_adpanel_systemd_service() {
  local service_name="adpanel"
  local service_file="/etc/systemd/system/${service_name}.service"
  local panel_root="$PANEL_ROOT"
  local runtime_script="${panel_root}/scripts/adpanel-runtime.sh"
  local monitor_script="${panel_root}/scripts/adpanel-autoscale-monitor.sh"
  local ecosystem_generator_script="${panel_root}/scripts/generate-ecosystem.sh"
  local ecosystem_template_file="${panel_root}/ecosystem.config.template.js"
  local ecosystem_file="${panel_root}/ecosystem.config.js"
  local prep_script="${panel_root}/start.sh"
  local pm2_runtime_bin="${panel_root}/node_modules/.bin/pm2-runtime"
  local pm2_home_dir="${panel_root}/.pm2"
  local exec_start_pre_line=""
  local service_user="root"
  local service_group="root"

  if ! systemd_available; then
    ui_warn "systemd is not available; skipping ${service_name} systemd service setup."
    return 1
  fi

  if [ ! -f "$runtime_script" ] || [ ! -f "$monitor_script" ] || [ ! -f "$ecosystem_generator_script" ]; then
    ui_error "Required PM2 runtime scripts are missing in ${panel_root}/scripts."
    return 1
  fi

  if [ ! -f "$ecosystem_template_file" ]; then
    ui_error "Expected ecosystem template not found at ${ecosystem_template_file}."
    return 1
  fi

  if [ ! -x "$pm2_runtime_bin" ] && ! cmd_exists pm2-runtime; then
    ui_error "pm2-runtime not found. Ensure dependencies are installed with npm install."
    return 1
  fi

  $SUDO chmod +x "$runtime_script" "$monitor_script" "$ecosystem_generator_script" >/dev/null 2>&1 || true

  if [ ! -f "$prep_script" ]; then
    ui_warn "Expected preparation script not found at ${prep_script}."
    ui_warn "The service will run as root without start.sh integration."
  else
    if ! $SUDO bash "$prep_script"; then
      ui_error "Failed to run start.sh preparation before creating the service."
      return 1
    fi

    if id -u adpanel >/dev/null 2>&1; then
      service_user="adpanel"
      service_group="adpanel"
      exec_start_pre_line="ExecStartPre=/bin/bash ${prep_script}"
    else
      ui_warn "start.sh completed but user 'adpanel' does not exist; the service will run as root."
    fi
  fi

  $SUDO mkdir -p "$pm2_home_dir" >/dev/null 2>&1 || true
  if id -u "$service_user" >/dev/null 2>&1; then
    $SUDO chown -R "$service_user":"$service_group" "$pm2_home_dir" >/dev/null 2>&1 || true
  fi

  if [ "$service_user" = "root" ]; then
    if ! "$ecosystem_generator_script" --panel-dir "$panel_root" >/dev/null; then
      ui_error "Failed to generate PM2 ecosystem configuration."
      return 1
    fi
  else
    if [ "$EUID" -eq 0 ]; then
      if cmd_exists runuser; then
        if ! runuser -u "$service_user" -- "$ecosystem_generator_script" --panel-dir "$panel_root" >/dev/null; then
          ui_error "Failed to generate PM2 ecosystem configuration for user ${service_user}."
          return 1
        fi
      else
        if ! su -s /bin/bash -c "\"$ecosystem_generator_script\" --panel-dir \"$panel_root\" >/dev/null" "$service_user"; then
          ui_error "Failed to generate PM2 ecosystem configuration for user ${service_user}."
          return 1
        fi
      fi
    else
      if ! $SUDO -u "$service_user" "$ecosystem_generator_script" --panel-dir "$panel_root" >/dev/null; then
        ui_error "Failed to generate PM2 ecosystem configuration for user ${service_user}."
        return 1
      fi
    fi
  fi

  cat <<EOF | $SUDO tee "$service_file" >/dev/null
[Unit]
Description=ADPanel PM2 Cluster Service
After=network.target adpanel-sshterm.service
Wants=adpanel-sshterm.service

[Service]
Type=simple
PermissionsStartOnly=true
WorkingDirectory=${panel_root}
User=${service_user}
Group=${service_group}
${exec_start_pre_line}
Environment=NODE_ENV=production
Environment=PANEL_DIR=${panel_root}
Environment=PM2_MONITOR_INTERVAL=300
Environment=PM2_HOME=${pm2_home_dir}
ExecStart=${runtime_script}
Restart=always
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=8
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  if cmd_exists restorecon; then
    $SUDO restorecon "$service_file" >/dev/null 2>&1 || true
  fi

  if ! $SUDO systemctl daemon-reload; then
    ui_error "Failed to reload systemd daemon after writing ${service_file}."
    return 1
  fi

  if ! $SUDO systemctl enable "$service_name"; then
    ui_error "Failed to enable ${service_name}.service."
    return 1
  fi

  if $SUDO systemctl is-active --quiet "$service_name"; then
    if ! $SUDO systemctl restart "$service_name"; then
      ui_error "Failed to restart ${service_name}.service."
      return 1
    fi
  else
    if ! $SUDO systemctl start "$service_name"; then
      ui_error "Failed to start ${service_name}.service."
      return 1
    fi
  fi

  if $SUDO systemctl is-active --quiet "$service_name"; then
    ui_success "${service_name}.service is active and enabled."
    if [ -f "$ecosystem_file" ]; then
      ui_info "PM2 ecosystem generated at: ${ecosystem_file}"
    fi
  else
    ui_warn "${service_name}.service was created and enabled but is not active."
    ui_warn "Check status with: systemctl status ${service_name}"
  fi

  return 0
}

setup_adpanel_openrc_service() {
  local service_name="adpanel"
  local service_file="/etc/init.d/${service_name}"
  local panel_root="$PANEL_ROOT"
  local runtime_script="${panel_root}/scripts/adpanel-runtime.sh"
  local monitor_script="${panel_root}/scripts/adpanel-autoscale-monitor.sh"
  local ecosystem_generator_script="${panel_root}/scripts/generate-ecosystem.sh"
  local pm2_runtime_bin="${panel_root}/node_modules/.bin/pm2-runtime"
  local pm2_home_dir="${panel_root}/.pm2"
  local prep_script="${panel_root}/start.sh"
  local service_user="root"
  local service_group="root"

  if ! cmd_exists rc-service || ! cmd_exists rc-update; then
    ui_warn "OpenRC tools not found; skipping ${service_name} OpenRC setup."
    return 1
  fi

  if [ ! -f "$runtime_script" ] || [ ! -f "$monitor_script" ] || [ ! -f "$ecosystem_generator_script" ]; then
    ui_error "Required PM2 runtime scripts are missing in ${panel_root}/scripts."
    return 1
  fi

  if [ ! -x "$pm2_runtime_bin" ] && ! cmd_exists pm2-runtime; then
    ui_error "pm2-runtime not found. Ensure dependencies are installed with npm install."
    return 1
  fi

  $SUDO chmod +x "$runtime_script" "$monitor_script" "$ecosystem_generator_script" >/dev/null 2>&1 || true

  if [ -f "$prep_script" ]; then
    if ! $SUDO bash "$prep_script"; then
      ui_warn "start.sh preparation failed; continuing OpenRC service setup as root."
    fi
  fi

  if id -u adpanel >/dev/null 2>&1; then
    service_user="adpanel"
    service_group="adpanel"
  fi

  $SUDO mkdir -p "$pm2_home_dir" /var/log >/dev/null 2>&1 || true
  if id -u "$service_user" >/dev/null 2>&1; then
    $SUDO chown -R "$service_user":"$service_group" "$pm2_home_dir" >/dev/null 2>&1 || true
  fi

  cat <<EOF | $SUDO tee "$service_file" >/dev/null
#!/sbin/openrc-run
name="ADPanel"
description="ADPanel PM2 Cluster Service"
directory="${panel_root}"
command="${runtime_script}"
command_user="${service_user}:${service_group}"
command_background=true
supervisor=supervise-daemon
pidfile="/run/${service_name}.pid"
output_log="/var/log/${service_name}.log"
error_log="/var/log/${service_name}.log"

export NODE_ENV="production"
export PANEL_DIR="${panel_root}"
export PM2_MONITOR_INTERVAL="300"
export PM2_HOME="${pm2_home_dir}"

depend() {
  need net
  after adpanel-sshterm mysql mariadb redis redis-server valkey nginx
}
EOF

  $SUDO chmod +x "$service_file" >/dev/null 2>&1 || true
  service_enable "$service_name"
  service_restart "$service_name"
  service_start "$service_name"

  if $SUDO rc-service "$service_name" status >/dev/null 2>&1; then
    ui_success "${service_name} OpenRC service is active and enabled."
    return 0
  fi

  ui_warn "${service_name} OpenRC service was created but is not active."
  ui_warn "Check status with: rc-service ${service_name} status"
  return 1
}

setup_adpanel_sysv_service() {
  local service_name="adpanel"
  local service_file="/etc/init.d/${service_name}"
  local panel_root="$PANEL_ROOT"
  local runtime_script="${panel_root}/scripts/adpanel-runtime.sh"
  local monitor_script="${panel_root}/scripts/adpanel-autoscale-monitor.sh"
  local ecosystem_generator_script="${panel_root}/scripts/generate-ecosystem.sh"
  local pm2_runtime_bin="${panel_root}/node_modules/.bin/pm2-runtime"
  local pm2_home_dir="${panel_root}/.pm2"
  local prep_script="${panel_root}/start.sh"
  local service_user="root"
  local service_group="root"

  if ! cmd_exists service; then
    ui_warn "SysV service command not found; skipping ${service_name} SysV setup."
    return 1
  fi

  if [ ! -f "$runtime_script" ] || [ ! -f "$monitor_script" ] || [ ! -f "$ecosystem_generator_script" ]; then
    ui_error "Required PM2 runtime scripts are missing in ${panel_root}/scripts."
    return 1
  fi

  if [ ! -x "$pm2_runtime_bin" ] && ! cmd_exists pm2-runtime; then
    ui_error "pm2-runtime not found. Ensure dependencies are installed with npm install."
    return 1
  fi

  $SUDO chmod +x "$runtime_script" "$monitor_script" "$ecosystem_generator_script" >/dev/null 2>&1 || true

  if [ -f "$prep_script" ]; then
    if ! $SUDO bash "$prep_script"; then
      ui_warn "start.sh preparation failed; continuing SysV service setup as root."
    fi
  fi

  if id -u adpanel >/dev/null 2>&1; then
    service_user="adpanel"
    service_group="adpanel"
  fi

  $SUDO mkdir -p "$pm2_home_dir" /var/log /var/run >/dev/null 2>&1 || true
  if id -u "$service_user" >/dev/null 2>&1; then
    $SUDO chown -R "$service_user":"$service_group" "$pm2_home_dir" >/dev/null 2>&1 || true
  fi

  cat <<EOF | $SUDO tee "$service_file" >/dev/null
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${service_name}
# Required-Start:    \$remote_fs \$network
# Should-Start:      adpanel-sshterm
# Required-Stop:     \$remote_fs \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ADPanel PM2 Cluster Service
### END INIT INFO

NAME="${service_name}"
PANEL_DIR="${panel_root}"
DAEMON="${runtime_script}"
PIDFILE="/var/run/${service_name}.pid"
LOGFILE="/var/log/${service_name}.log"
SERVICE_USER="${service_user}"
PM2_HOME="${pm2_home_dir}"

start() {
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
    echo "\$NAME is already running"
    return 0
  fi
  echo "Starting \$NAME"
  if command -v start-stop-daemon >/dev/null 2>&1; then
    if [ "\$SERVICE_USER" = "root" ]; then
      start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" --chdir "\$PANEL_DIR" --startas /bin/sh -- -c "NODE_ENV=production PANEL_DIR='\$PANEL_DIR' PM2_MONITOR_INTERVAL=300 PM2_HOME='\$PM2_HOME' exec '\$DAEMON' >>'\$LOGFILE' 2>&1"
    else
      start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" --chuid "\$SERVICE_USER" --chdir "\$PANEL_DIR" --startas /bin/sh -- -c "NODE_ENV=production PANEL_DIR='\$PANEL_DIR' PM2_MONITOR_INTERVAL=300 PM2_HOME='\$PM2_HOME' exec '\$DAEMON' >>'\$LOGFILE' 2>&1"
    fi
  else
    if [ "\$SERVICE_USER" != "root" ] && command -v su >/dev/null 2>&1; then
      su -s /bin/sh -c "cd '\$PANEL_DIR' && NODE_ENV=production PANEL_DIR='\$PANEL_DIR' PM2_MONITOR_INTERVAL=300 PM2_HOME='\$PM2_HOME' nohup '\$DAEMON' >>'\$LOGFILE' 2>&1 & echo \\\$! > '\$PIDFILE'" "\$SERVICE_USER"
    else
      (cd "\$PANEL_DIR" && NODE_ENV=production PANEL_DIR="\$PANEL_DIR" PM2_MONITOR_INTERVAL=300 PM2_HOME="\$PM2_HOME" nohup "\$DAEMON" >>"\$LOGFILE" 2>&1 & echo \$! > "\$PIDFILE")
    fi
  fi
}

stop() {
  echo "Stopping \$NAME"
  if command -v start-stop-daemon >/dev/null 2>&1; then
    start-stop-daemon --stop --pidfile "\$PIDFILE" --retry TERM/8/KILL/3 >/dev/null 2>&1 || true
  elif [ -f "\$PIDFILE" ]; then
    kill "\$(cat "\$PIDFILE")" >/dev/null 2>&1 || true
  fi
  rm -f "\$PIDFILE"
}

status() {
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
    echo "\$NAME is running"
    return 0
  fi
  echo "\$NAME is not running"
  return 3
}

case "\$1" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF

  $SUDO chmod +x "$service_file" >/dev/null 2>&1 || true
  service_enable "$service_name"
  service_restart "$service_name"
  service_start "$service_name"

  if $SUDO service "$service_name" status >/dev/null 2>&1; then
    ui_success "${service_name} SysV service is active and enabled."
    return 0
  fi

  ui_warn "${service_name} SysV service was created but is not active."
  ui_warn "Check status with: service ${service_name} status"
  return 1
}

setup_adpanel_service() {
  case "$INIT_SYSTEM" in
    systemd)
      setup_adpanel_systemd_service
      ;;
    openrc)
      setup_adpanel_openrc_service
      ;;
    sysv)
      setup_adpanel_sysv_service
      ;;
    *)
      ui_error "No supported init system detected. Start manually with: npm start"
      return 1
      ;;
  esac
}

print_adpanel_service_commands() {
  case "$INIT_SYSTEM" in
    systemd)
      ui_success "You can now manage ADPanel with systemd:"
      ui_kv "  Start:" "systemctl start adpanel"
      ui_kv "  Stop:" "systemctl stop adpanel"
      ui_kv "  Restart:" "systemctl restart adpanel"
      ui_kv "  Status:" "systemctl status adpanel"
      ;;
    openrc)
      ui_success "You can now manage ADPanel with OpenRC:"
      ui_kv "  Start:" "rc-service adpanel start"
      ui_kv "  Stop:" "rc-service adpanel stop"
      ui_kv "  Restart:" "rc-service adpanel restart"
      ui_kv "  Status:" "rc-service adpanel status"
      ;;
    sysv)
      ui_success "You can now manage ADPanel with SysV init:"
      ui_kv "  Start:" "service adpanel start"
      ui_kv "  Stop:" "service adpanel stop"
      ui_kv "  Restart:" "service adpanel restart"
      ui_kv "  Status:" "service adpanel status"
      ;;
  esac
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 1
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
    | tail -n 1 \
    | sed -E "s/^[^=]*=[[:space:]]*//; s/^['\"]//; s/['\"]$//"
}

resolve_sshterm_port() {
  local panel_root="$1"
  local port="${SSH_TERM_PORT:-}"
  if [ -z "$port" ]; then
    port="$(read_env_file_value "${panel_root}/.env" "SSH_TERM_PORT" || true)"
  fi
  normalize_port "$port" "9393"
}

resolve_sshterm_bind() {
  local panel_root="$1"
  local port="$2"
  local bind="${SSH_TERM_BIND:-}"
  if [ -z "$bind" ]; then
    bind="$(read_env_file_value "${panel_root}/.env" "SSH_TERM_BIND" || true)"
  fi
  if [ -z "$bind" ]; then
    bind="127.0.0.1:${port}"
  elif printf "%s" "$bind" | grep -qE '^[0-9]+$'; then
    bind="127.0.0.1:${bind}"
  fi
  printf "%s" "$bind"
}

sshterm_bind_host() {
  local value
  value="$(trim_ws "${1:-}")"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"

  if printf "%s" "$value" | grep -qE '^\[[^]]+\](:[0-9]+)?$'; then
    value="${value#\[}"
    value="${value%%\]*}"
  elif printf "%s" "$value" | grep -qE '^[^:]+:[0-9]+$'; then
    value="${value%:*}"
  elif printf "%s" "$value" | grep -qE '^:[0-9]+$'; then
    value=""
  fi

  printf "%s" "$value"
}

sshterm_bind_is_loopback() {
  local host
  host="$(lower_trim "$(sshterm_bind_host "${1:-}")")"
  case "$host" in
    localhost|127.*|::1)
      return 0
      ;;
  esac
  return 1
}

build_sshterm_health_url() {
  local bind="$1"
  local port="$2"
  local host
  host="$(sshterm_bind_host "$bind")"
  case "$(lower_trim "$host")" in
    ""|0.0.0.0|::|\*)
      host="127.0.0.1"
      ;;
  esac
  if printf "%s" "$host" | grep -q ':' && ! printf "%s" "$host" | grep -qE '^\[.*\]$'; then
    host="[${host}]"
  fi
  printf "http://%s:%s/healthz" "$host" "$port"
}

allow_tcp_firewall_port() {
  local port="$1"
  local label="${2:-service}"
  [ -n "$port" ] || return 0

  if cmd_exists ufw; then
    preserve_ssh_firewall_access ufw
    $SUDO ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    if $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
      $SUDO ufw reload >/dev/null 2>&1 || true
    fi
    ui_success "Firewall allows ${label} on TCP port ${port} with ufw."
    return 0
  fi

  if cmd_exists firewall-cmd; then
    service_enable firewalld
    service_start firewalld
    preserve_ssh_firewall_access firewalld
    $SUDO firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    ui_success "Firewall allows ${label} on TCP port ${port} with firewalld."
    return 0
  fi

  if cmd_exists iptables; then
    preserve_ssh_firewall_access iptables
    $SUDO iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
      $SUDO iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    if cmd_exists netfilter-persistent; then
      $SUDO netfilter-persistent save >/dev/null 2>&1 || true
    elif [ -d /etc/iptables ] && cmd_exists iptables-save; then
      $SUDO sh -c "iptables-save > /etc/iptables/rules.v4" >/dev/null 2>&1 || true
    fi
    ui_success "Firewall allows ${label} on TCP port ${port} with iptables."
    return 0
  fi

  if cmd_exists nft && $SUDO nft list table inet filter >/dev/null 2>&1; then
    preserve_ssh_firewall_access nftables
    $SUDO nft add rule inet filter input tcp dport "$port" accept >/dev/null 2>&1 || true
    ui_success "Firewall allows ${label} on TCP port ${port} with nftables."
    return 0
  fi

  ui_warn "No supported firewall manager found; allow TCP port ${port} manually if ${label} is exposed publicly."
  return 0
}

bind_host_is_loopback() {
  local host
  host="$(lower_trim "${1:-}")"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  host="${host%\]}"
  host="${host#\[}"
  if printf "%s" "$host" | grep -qE '^[^:]+:[0-9]+$'; then
    host="${host%:*}"
  fi

  case "$host" in
    localhost|127.*|::1)
      return 0
      ;;
  esac
  return 1
}

auto_open_firewall_enabled() {
  local value
  value="$(lower_trim "${ADPANEL_AUTO_OPEN_FIREWALL:-1}")"
  case "$value" in
    0|false|no|off)
      return 1
      ;;
  esac
  return 0
}

open_public_firewall_port() {
  local port="$1"
  local label="${2:-ADPanel}"
  local bind_host="${3:-0.0.0.0}"

  [ -n "$port" ] || return 0
  if ! printf "%s" "$port" | grep -qE '^[0-9]+$'; then
    return 0
  fi
  if bind_host_is_loopback "$bind_host"; then
    ui_info "${label} binds to ${bind_host}; no public firewall rule is needed."
    return 0
  fi
  if ! auto_open_firewall_enabled; then
    ui_warn "Automatic firewall opening is disabled. Allow TCP port ${port} manually for ${label}."
    return 0
  fi

  if cmd_exists firewall-cmd && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    preserve_ssh_firewall_access firewalld
    $SUDO firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    ui_success "Firewall allows ${label} on TCP port ${port} with firewalld."
    return 0
  fi

  if cmd_exists ufw && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    preserve_ssh_firewall_access ufw
    $SUDO ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    $SUDO ufw reload >/dev/null 2>&1 || true
    ui_success "Firewall allows ${label} on TCP port ${port} with ufw."
    return 0
  fi

  if cmd_exists iptables; then
    preserve_ssh_firewall_access iptables
    $SUDO iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
      $SUDO iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    if cmd_exists netfilter-persistent; then
      $SUDO netfilter-persistent save >/dev/null 2>&1 || true
    elif [ -d /etc/iptables ] && cmd_exists iptables-save; then
      $SUDO sh -c "iptables-save > /etc/iptables/rules.v4" >/dev/null 2>&1 || true
    fi
    ui_success "Firewall allows ${label} on TCP port ${port} with iptables."
    return 0
  fi

  ui_warn "No active supported firewall was detected. If this VPS filters traffic, allow TCP port ${port} for ${label}."
  return 0
}

configure_panel_firewall() {
  local nginx_enabled="${1:-false}"
  local bind_host="${2:-0.0.0.0}"
  local http_port="${3:-}"
  local https_enabled="${4:-false}"
  local https_port="${5:-}"

  if [ "$nginx_enabled" == "true" ]; then
    bind_host="0.0.0.0"
  fi

  open_public_firewall_port "$http_port" "ADPanel HTTP" "$bind_host"
  if [ "$https_enabled" == "true" ]; then
    open_public_firewall_port "$https_port" "ADPanel HTTPS" "$bind_host"
  fi
}

configure_sshterm_firewall() {
  local port="$1"
  local bind="$2"

  if sshterm_bind_is_loopback "$bind"; then
    ui_info "SSH terminal binds to ${bind}; no public firewall rule is needed."
    return 0
  fi

  allow_tcp_firewall_port "$port" "ADPanel SSH terminal"
}

ensure_sshterm_source_available() {
  local panel_root="${1:-$PANEL_ROOT}"
  local raw_base="${ADPANEL_SOURCE_RAW_BASE%/}"
  local missing=false
  local rel=""

  for rel in go.mod go.sum cmd/sshterm/main.go; do
    if [ ! -f "${panel_root}/${rel}" ]; then
      missing=true
    fi
  done

  if [ "$missing" != "true" ]; then
    return 0
  fi

  ui_warn "SSH terminal source files are missing; trying to recover them from ${raw_base}..."
  for rel in go.mod go.sum cmd/sshterm/main.go; do
    if [ -f "${panel_root}/${rel}" ]; then
      continue
    fi

    local dest="${panel_root}/${rel}"
    local tmp=""
    tmp="$(mktemp /tmp/adpanel-sshterm-src.XXXXXX 2>/dev/null || echo "")"
    if [ -z "$tmp" ]; then
      ui_warn "Could not create temp file while recovering ${rel}."
      return 1
    fi

    if ! download_file "${raw_base}/${rel}" "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp" >/dev/null 2>&1 || true
      ui_warn "Could not download ${rel}. Make sure the ADPanel release includes cmd/sshterm and go.mod/go.sum."
      return 1
    fi

    $SUDO mkdir -p "$(dirname "$dest")" >/dev/null 2>&1 || true
    if ! $SUDO mv "$tmp" "$dest"; then
      rm -f "$tmp" >/dev/null 2>&1 || true
      ui_warn "Could not install recovered ${rel} into ${dest}."
      return 1
    fi
    $SUDO chmod 0644 "$dest" >/dev/null 2>&1 || true
    if id -u adpanel >/dev/null 2>&1; then
      $SUDO chown adpanel:adpanel "$dest" >/dev/null 2>&1 || true
    fi
  done

  [ -f "${panel_root}/cmd/sshterm/main.go" ] && [ -f "${panel_root}/go.mod" ] && [ -f "${panel_root}/go.sum" ]
}

prepare_adpanel_sshterm_runtime() {
  local panel_root="$PANEL_ROOT"
  local prep_script="${panel_root}/start.sh"
  local sshterm_main="${panel_root}/cmd/sshterm/main.go"
  local sshterm_bin="${panel_root}/.bin/adpanel-sshterm"
  local sshterm_exec="/usr/local/bin/adpanel-sshterm"
  local go_cache_dir="${panel_root}/.cache-go"
  local go_modcache_dir="${panel_root}/.gomodcache"
  local go_bin=""
  local service_user="root"
  local service_group="root"

  if ! cmd_exists go; then
    ui_warn "Go runtime not found; skipping ADPanel SSH terminal service setup."
    return 1
  fi
  go_bin="$(command -v go 2>/dev/null || true)"
  if [ -z "$go_bin" ]; then
    ui_warn "Go runtime path could not be resolved; skipping ADPanel SSH terminal service setup."
    return 1
  fi

  if ! ensure_sshterm_source_available "$panel_root"; then
    ui_warn "SSH terminal source could not be recovered; skipping service setup."
    return 1
  fi

  if [ ! -f "$sshterm_main" ]; then
    ui_warn "SSH terminal source not found at ${sshterm_main}; skipping service setup."
    return 1
  fi

  if [ -f "$prep_script" ]; then
    ui_info "Preparing ADPanel runtime user and permissions for SSH terminal..."
    if ! $SUDO bash "$prep_script"; then
      ui_warn "Runtime preparation failed before SSH terminal service setup; continuing best effort."
    fi
  fi

  if id -u adpanel >/dev/null 2>&1; then
    service_user="adpanel"
    service_group="adpanel"
  fi

  ensure_panel_env_permissions "$panel_root"

  $SUDO mkdir -p "$go_cache_dir" "$go_modcache_dir" "${panel_root}/.bin" >/dev/null 2>&1 || true
  $SUDO chown -R "${service_user}:${service_group}" "$go_cache_dir" "$go_modcache_dir" "${panel_root}/.bin" >/dev/null 2>&1 || true

  ui_info "Building ADPanel SSH terminal binary..."
  if ! $SUDO env \
      HOME="$panel_root" \
      GOCACHE="$go_cache_dir" \
      GOMODCACHE="$go_modcache_dir" \
      GOMAXPROCS=2 \
      "$go_bin" build -trimpath -buildvcs=false -ldflags="-s -w" -o "$sshterm_bin" ./cmd/sshterm; then
    ui_warn "Failed to build ADPanel SSH terminal; service cannot be started."
    return 1
  fi

  $SUDO chmod 0755 "$sshterm_bin" >/dev/null 2>&1 || true
  $SUDO chown "${service_user}:${service_group}" "$sshterm_bin" >/dev/null 2>&1 || true
  $SUDO mkdir -p "$(dirname "$sshterm_exec")" >/dev/null 2>&1 || true
  if ! $SUDO install -m 0755 -o root -g root "$sshterm_bin" "$sshterm_exec"; then
    ui_warn "Failed to install SSH terminal binary to ${sshterm_exec}; using project-local binary."
    sshterm_exec="$sshterm_bin"
  elif cmd_exists restorecon; then
    $SUDO restorecon "$sshterm_exec" >/dev/null 2>&1 || true
  fi

  SSHTERM_PANEL_ROOT="$panel_root"
  SSHTERM_EXEC="$sshterm_exec"
  SSHTERM_GO_CACHE_DIR="$go_cache_dir"
  SSHTERM_GO_MODCACHE_DIR="$go_modcache_dir"
  SSHTERM_SERVICE_USER="$service_user"
  SSHTERM_SERVICE_GROUP="$service_group"
  SSHTERM_PORT="$(resolve_sshterm_port "$panel_root")"
  SSHTERM_BIND="$(resolve_sshterm_bind "$panel_root" "$SSHTERM_PORT")"
  SSHTERM_HEALTH_URL="$(build_sshterm_health_url "$SSHTERM_BIND" "$SSHTERM_PORT")"

  configure_sshterm_firewall "$SSHTERM_PORT" "$SSHTERM_BIND"
  return 0
}

setup_adpanel_sshterm_systemd_service() {
  local service_name="adpanel-sshterm"
  local service_file="/etc/systemd/system/${service_name}.service"
  local panel_root="$PANEL_ROOT"
  local prep_script="${panel_root}/start.sh"
  local sshterm_main="${panel_root}/cmd/sshterm/main.go"
  local sshterm_bin="${panel_root}/.bin/adpanel-sshterm"
  local sshterm_exec="/usr/local/bin/adpanel-sshterm"
  local go_cache_dir="${panel_root}/.cache-go"
  local go_modcache_dir="${panel_root}/.gomodcache"
  local go_bin=""
  local sshterm_port=""
  local sshterm_bind=""
  local sshterm_health_url=""
  local service_user="root"
  local service_group="root"

  if ! systemd_available; then
    ui_warn "systemd is not available; skipping ${service_name} systemd service setup."
    return 1
  fi

  if ! cmd_exists go; then
    ui_warn "Go runtime not found; skipping ${service_name} service setup."
    return 1
  fi
  go_bin="$(command -v go 2>/dev/null || true)"
  if [ -z "$go_bin" ]; then
    ui_warn "Go runtime path could not be resolved; skipping ${service_name} service setup."
    return 1
  fi

  if ! ensure_sshterm_source_available "$panel_root"; then
    ui_warn "SSH terminal source could not be recovered; skipping ${service_name} setup."
    return 1
  fi

  if [ ! -f "$sshterm_main" ]; then
    ui_warn "SSH terminal source not found at ${sshterm_main}; skipping ${service_name} setup."
    return 1
  fi

  sshterm_port="$(resolve_sshterm_port "$panel_root")"
  sshterm_bind="$(resolve_sshterm_bind "$panel_root" "$sshterm_port")"
  sshterm_health_url="$(build_sshterm_health_url "$sshterm_bind" "$sshterm_port")"

  if [ -f "$prep_script" ]; then
    ui_info "Preparing ADPanel runtime user and permissions for SSH terminal..."
    if ! $SUDO bash "$prep_script"; then
      ui_warn "Runtime preparation failed before ${service_name}; continuing with best-effort service setup."
    fi
  fi

  if id -u adpanel >/dev/null 2>&1; then
    service_user="adpanel"
    service_group="adpanel"
  fi

  ensure_panel_env_permissions "$panel_root"

  $SUDO mkdir -p "$go_cache_dir" "$go_modcache_dir" "${panel_root}/.bin" >/dev/null 2>&1 || true
  $SUDO chown -R "${service_user}:${service_group}" "$go_cache_dir" "$go_modcache_dir" "${panel_root}/.bin" >/dev/null 2>&1 || true

  ui_info "Building ADPanel SSH terminal binary..."
  if ! $SUDO env \
      HOME="$panel_root" \
      GOCACHE="$go_cache_dir" \
      GOMODCACHE="$go_modcache_dir" \
      GOMAXPROCS=2 \
      "$go_bin" build -trimpath -buildvcs=false -ldflags="-s -w" -o "$sshterm_bin" ./cmd/sshterm; then
    ui_warn "Failed to build ${service_name}; SSH terminal service cannot be started."
    return 1
  fi
  $SUDO chmod 0755 "$sshterm_bin" >/dev/null 2>&1 || true
  $SUDO chown "${service_user}:${service_group}" "$sshterm_bin" >/dev/null 2>&1 || true
  $SUDO mkdir -p "$(dirname "$sshterm_exec")" >/dev/null 2>&1 || true
  if ! $SUDO install -m 0755 -o root -g root "$sshterm_bin" "$sshterm_exec"; then
    ui_warn "Failed to install ${service_name} binary to ${sshterm_exec}; using project-local binary."
    sshterm_exec="$sshterm_bin"
  elif cmd_exists restorecon; then
    $SUDO restorecon "$sshterm_exec" >/dev/null 2>&1 || true
  fi
  configure_sshterm_firewall "$sshterm_port" "$sshterm_bind"

  cat <<EOF | $SUDO tee "$service_file" >/dev/null
[Unit]
Description=ADPanel SSH Terminal Service
After=network-online.target
Wants=network-online.target
Before=adpanel.service
PartOf=adpanel.service

[Service]
Type=simple
WorkingDirectory=${panel_root}
User=${service_user}
Group=${service_group}
EnvironmentFile=-${panel_root}/.env
Environment=SSH_TERM_PANEL_ROOT=${panel_root}
Environment=SSH_TERM_BIND=${sshterm_bind}
Environment=SSH_TERM_PORT=${sshterm_port}
Environment=ENABLE_HTTPS=false
Environment=HOME=${panel_root}
Environment=GOCACHE=${go_cache_dir}
Environment=GOMODCACHE=${go_modcache_dir}
Environment=GOMAXPROCS=1
Environment=GOMEMLIMIT=128MiB
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${sshterm_exec}
NoNewPrivileges=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  if cmd_exists restorecon; then
    $SUDO restorecon "$service_file" >/dev/null 2>&1 || true
  fi

  if ! $SUDO systemctl daemon-reload; then
    ui_warn "Failed to reload systemd daemon for ${service_name}."
    return 1
  fi

  $SUDO systemctl enable "$service_name" >/dev/null 2>&1 || true
  if $SUDO systemctl is-active --quiet "$service_name"; then
    $SUDO systemctl restart "$service_name" >/dev/null 2>&1 || true
  else
    $SUDO systemctl start "$service_name" >/dev/null 2>&1 || true
  fi

  if $SUDO systemctl is-active --quiet "$service_name"; then
    if cmd_exists curl; then
      local health_ok=false
      local i
      for i in 1 2 3 4 5; do
        if curl -fsS --max-time 5 "$sshterm_health_url" >/dev/null 2>&1; then
          health_ok=true
          break
        fi
        sleep 1
      done
      if [ "$health_ok" != "true" ]; then
        ui_warn "${service_name}.service is active but its local health check failed."
        ui_warn "Health check URL: ${sshterm_health_url}"
        ui_warn "Check logs with: journalctl -u ${service_name} -n 80 --no-pager"
        $SUDO journalctl -u "$service_name" -n 20 --no-pager 2>/dev/null || true
        return 1
      fi
    fi
    ui_success "${service_name}.service is active and enabled."
  else
    ui_warn "${service_name}.service was created but is not active."
    ui_warn "Check status with: systemctl status ${service_name}"
    $SUDO systemctl status "$service_name" --no-pager -l 2>/dev/null || true
  fi

  return 0
}

setup_adpanel_sshterm_openrc_service() {
  local service_name="adpanel-sshterm"
  local service_file="/etc/init.d/${service_name}"

  if ! cmd_exists rc-service || ! cmd_exists rc-update; then
    ui_warn "OpenRC tools not found; skipping ${service_name} setup."
    return 1
  fi

  if ! prepare_adpanel_sshterm_runtime; then
    return 1
  fi

  cat <<EOF | $SUDO tee "$service_file" >/dev/null
#!/sbin/openrc-run
name="ADPanel SSH Terminal"
description="ADPanel SSH Terminal Service"
directory="${SSHTERM_PANEL_ROOT}"
command="${SSHTERM_EXEC}"
command_user="${SSHTERM_SERVICE_USER}:${SSHTERM_SERVICE_GROUP}"
command_background=true
supervisor=supervise-daemon
pidfile="/run/${service_name}.pid"
output_log="/var/log/${service_name}.log"
error_log="/var/log/${service_name}.log"

export SSH_TERM_PANEL_ROOT="${SSHTERM_PANEL_ROOT}"
export SSH_TERM_BIND="${SSHTERM_BIND}"
export SSH_TERM_PORT="${SSHTERM_PORT}"
export ENABLE_HTTPS="false"
export HOME="${SSHTERM_PANEL_ROOT}"
export GOCACHE="${SSHTERM_GO_CACHE_DIR}"
export GOMODCACHE="${SSHTERM_GO_MODCACHE_DIR}"
export GOMAXPROCS="1"
export GOMEMLIMIT="128MiB"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

depend() {
  need net
  before adpanel
}
EOF

  $SUDO chmod +x "$service_file" >/dev/null 2>&1 || true
  service_enable "$service_name"
  service_restart "$service_name"
  service_start "$service_name"

  if $SUDO rc-service "$service_name" status >/dev/null 2>&1; then
    if cmd_exists curl && ! curl -fsS --max-time 5 "$SSHTERM_HEALTH_URL" >/dev/null 2>&1; then
      ui_warn "${service_name} OpenRC service is active but its local health check failed."
      ui_warn "Health check URL: ${SSHTERM_HEALTH_URL}"
      return 1
    fi
    ui_success "${service_name} OpenRC service is active and enabled."
    return 0
  fi

  ui_warn "${service_name} OpenRC service was created but is not active."
  ui_warn "Check status with: rc-service ${service_name} status"
  return 1
}

setup_adpanel_sshterm_sysv_service() {
  local service_name="adpanel-sshterm"
  local service_file="/etc/init.d/${service_name}"

  if ! cmd_exists service; then
    ui_warn "SysV service command not found; skipping ${service_name} setup."
    return 1
  fi

  if ! prepare_adpanel_sshterm_runtime; then
    return 1
  fi

  cat <<EOF | $SUDO tee "$service_file" >/dev/null
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${service_name}
# Required-Start:    \$remote_fs \$network
# Required-Stop:     \$remote_fs \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ADPanel SSH Terminal Service
### END INIT INFO

NAME="${service_name}"
PANEL_DIR="${SSHTERM_PANEL_ROOT}"
DAEMON="${SSHTERM_EXEC}"
PIDFILE="/var/run/${service_name}.pid"
LOGFILE="/var/log/${service_name}.log"
SERVICE_USER="${SSHTERM_SERVICE_USER}"

start() {
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
    echo "\$NAME is already running"
    return 0
  fi
  echo "Starting \$NAME"
  if command -v start-stop-daemon >/dev/null 2>&1; then
    if [ "\$SERVICE_USER" = "root" ]; then
      start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" --chdir "\$PANEL_DIR" --startas /bin/sh -- -c "SSH_TERM_PANEL_ROOT='${SSHTERM_PANEL_ROOT}' SSH_TERM_BIND='${SSHTERM_BIND}' SSH_TERM_PORT='${SSHTERM_PORT}' ENABLE_HTTPS=false HOME='${SSHTERM_PANEL_ROOT}' GOCACHE='${SSHTERM_GO_CACHE_DIR}' GOMODCACHE='${SSHTERM_GO_MODCACHE_DIR}' GOMAXPROCS=1 GOMEMLIMIT=128MiB PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin exec '\$DAEMON' >>'\$LOGFILE' 2>&1"
    else
      start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" --chuid "\$SERVICE_USER" --chdir "\$PANEL_DIR" --startas /bin/sh -- -c "SSH_TERM_PANEL_ROOT='${SSHTERM_PANEL_ROOT}' SSH_TERM_BIND='${SSHTERM_BIND}' SSH_TERM_PORT='${SSHTERM_PORT}' ENABLE_HTTPS=false HOME='${SSHTERM_PANEL_ROOT}' GOCACHE='${SSHTERM_GO_CACHE_DIR}' GOMODCACHE='${SSHTERM_GO_MODCACHE_DIR}' GOMAXPROCS=1 GOMEMLIMIT=128MiB PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin exec '\$DAEMON' >>'\$LOGFILE' 2>&1"
    fi
  else
    if [ "\$SERVICE_USER" != "root" ] && command -v su >/dev/null 2>&1; then
      su -s /bin/sh -c "cd '\$PANEL_DIR' && SSH_TERM_PANEL_ROOT='${SSHTERM_PANEL_ROOT}' SSH_TERM_BIND='${SSHTERM_BIND}' SSH_TERM_PORT='${SSHTERM_PORT}' ENABLE_HTTPS=false HOME='${SSHTERM_PANEL_ROOT}' GOCACHE='${SSHTERM_GO_CACHE_DIR}' GOMODCACHE='${SSHTERM_GO_MODCACHE_DIR}' GOMAXPROCS=1 GOMEMLIMIT=128MiB PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin nohup '\$DAEMON' >>'\$LOGFILE' 2>&1 & echo \\\$! > '\$PIDFILE'" "\$SERVICE_USER"
    else
      (cd "\$PANEL_DIR" && SSH_TERM_PANEL_ROOT="${SSHTERM_PANEL_ROOT}" SSH_TERM_BIND="${SSHTERM_BIND}" SSH_TERM_PORT="${SSHTERM_PORT}" ENABLE_HTTPS=false HOME="${SSHTERM_PANEL_ROOT}" GOCACHE="${SSHTERM_GO_CACHE_DIR}" GOMODCACHE="${SSHTERM_GO_MODCACHE_DIR}" GOMAXPROCS=1 GOMEMLIMIT=128MiB PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin nohup "\$DAEMON" >>"\$LOGFILE" 2>&1 & echo \$! > "\$PIDFILE")
    fi
  fi
}

stop() {
  echo "Stopping \$NAME"
  if command -v start-stop-daemon >/dev/null 2>&1; then
    start-stop-daemon --stop --pidfile "\$PIDFILE" --retry TERM/8/KILL/3 >/dev/null 2>&1 || true
  elif [ -f "\$PIDFILE" ]; then
    kill "\$(cat "\$PIDFILE")" >/dev/null 2>&1 || true
  fi
  rm -f "\$PIDFILE"
}

status() {
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
    echo "\$NAME is running"
    return 0
  fi
  echo "\$NAME is not running"
  return 3
}

case "\$1" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF

  $SUDO chmod +x "$service_file" >/dev/null 2>&1 || true
  service_enable "$service_name"
  service_restart "$service_name"
  service_start "$service_name"

  if $SUDO service "$service_name" status >/dev/null 2>&1; then
    if cmd_exists curl && ! curl -fsS --max-time 5 "$SSHTERM_HEALTH_URL" >/dev/null 2>&1; then
      ui_warn "${service_name} SysV service is active but its local health check failed."
      ui_warn "Health check URL: ${SSHTERM_HEALTH_URL}"
      return 1
    fi
    ui_success "${service_name} SysV service is active and enabled."
    return 0
  fi

  ui_warn "${service_name} SysV service was created but is not active."
  ui_warn "Check status with: service ${service_name} status"
  return 1
}

setup_adpanel_sshterm_service() {
  case "$INIT_SYSTEM" in
    systemd)
      setup_adpanel_sshterm_systemd_service
      ;;
    openrc)
      setup_adpanel_sshterm_openrc_service
      ;;
    sysv)
      setup_adpanel_sshterm_sysv_service
      ;;
    *)
      ui_warn "SSH terminal service setup skipped because init system is unsupported: ${INIT_SYSTEM}."
      return 1
      ;;
  esac
}

install_certbot() {
  ui_info "Installing certbot..."
  if command -v certbot >/dev/null 2>&1; then
    ui_success "certbot is already installed."
    return 0
  fi

  if ! ensure_supported_package_manager; then
    ui_error "Could not detect a supported package manager to install certbot."
    ui_warn "Please install certbot manually and re-run initialization."
    return 1
  fi

  enable_rhel_extra_repos
  ensure_pkg_metadata >/dev/null 2>&1 || true

  if ! pkg_install_try_sets "certbot" "python3-certbot"; then
    ui_error "certbot installation failed."
    return 1
  fi

  if command -v certbot >/dev/null 2>&1; then
    ui_success "certbot installed successfully."
    return 0
  fi

  ui_error "certbot installation failed."
  return 1
}

ensure_certbot_nginx_plugin() {
  if command -v certbot >/dev/null 2>&1; then
    if certbot plugins 2>/dev/null | grep -qi "nginx"; then
      ui_success "certbot nginx plugin is already available."
      return 0
    fi
  fi

  ui_info "Installing certbot nginx plugin..."
  if ! ensure_supported_package_manager; then
    ui_warn "No supported package manager found for certbot nginx plugin."
    return 1
  fi

  enable_rhel_extra_repos
  ensure_pkg_metadata >/dev/null 2>&1 || true

  if ! pkg_install_try_sets \
      "python3-certbot-nginx" \
      "certbot-nginx" \
      "python-certbot-nginx" \
      "py3-certbot-nginx"; then
    ui_warn "Could not install certbot nginx plugin automatically."
    return 1
  fi

  if command -v certbot >/dev/null 2>&1 && certbot plugins 2>/dev/null | grep -qi "nginx"; then
    ui_success "certbot nginx plugin installed."
    return 0
  fi

  ui_warn "certbot nginx plugin might not be available on this system."
  return 1
}

install_nginx() {
  ui_info "Installing nginx..."
  if command -v nginx >/dev/null 2>&1; then
    ui_success "nginx is already installed."
    ensure_certbot_nginx_plugin >/dev/null 2>&1 || true
    return 0
  fi

  if ! ensure_supported_package_manager; then
    ui_error "Could not detect a supported package manager to install nginx."
    ui_warn "Please install nginx manually and re-run initialization."
    return 1
  fi

  enable_rhel_extra_repos
  ensure_pkg_metadata >/dev/null 2>&1 || true
  if ! pkg_install nginx; then
    ui_error "nginx installation failed."
    return 1
  fi

  ensure_certbot_nginx_plugin >/dev/null 2>&1 || true
  if command -v nginx >/dev/null 2>&1; then
    ui_success "nginx installed successfully."
    return 0
  fi

  ui_error "nginx installation failed."
  return 1
}

install_optional_nginx_brotli_module() {
  if ! ensure_supported_package_manager; then
    return 1
  fi

  ensure_pkg_metadata >/dev/null 2>&1 || true

  case "$PKG_MGR" in
    apt)
      pkg_install_try_sets \
        "libnginx-mod-brotli" \
        "nginx-mod-http-brotli"
      ;;
    dnf|yum)
      pkg_install_try_sets \
        "nginx-mod-brotli" \
        "nginx-module-brotli" \
        "nginx-mod-http-brotli"
      ;;
    zypper)
      pkg_install_try_sets \
        "nginx-module-brotli" \
        "nginx-mod-brotli"
      ;;
    pacman)
      pkg_install_try_sets \
        "nginx-mod-brotli" \
        "nginx-mainline-mod-brotli"
      ;;
    apk)
      pkg_install_try_sets \
        "nginx-mod-http-brotli" \
        "nginx-brotli"
      ;;
    *)
      return 1
      ;;
  esac
}

is_redis_installed() {
  command -v redis-server >/dev/null 2>&1 || command -v redis-cli >/dev/null 2>&1 || \
  command -v valkey-server >/dev/null 2>&1 || command -v valkey-cli >/dev/null 2>&1
}


is_mysql_installed() {
  command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1 || \
  command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1
}

mysql_detect_cli() {
  if cmd_exists mysql; then
    echo "mysql"
  elif cmd_exists mariadb; then
    echo "mariadb"
  else
    echo "mysql"
  fi
}

mysql_detect_service_candidates() {
  echo "mysql"
  echo "mysqld"
  echo "mariadb"
  echo "mariadb-server"
}

mysql_find_service() {
  local svc=""
  if [ "$INIT_SYSTEM" == "systemd" ]; then
    local cand
    while read -r cand; do
      if systemctl list-unit-files 2>/dev/null | grep -qE "^${cand}\.service"; then
        svc="$cand"
        break
      fi
    done < <(mysql_detect_service_candidates)
    echo "$svc"
    return 0
  fi

  local cand
  while read -r cand; do
    if [ -x "/etc/init.d/${cand}" ] || [ -f "/etc/init.d/${cand}" ]; then
      svc="$cand"
      break
    fi
  done < <(mysql_detect_service_candidates)

  if [ -n "$svc" ]; then
    echo "$svc"
  else
    echo "mariadb"
  fi
  return 0
}

mysql_init_datadir_if_needed() {
  if [ -d /var/lib/mysql/mysql ]; then
    return 0
  fi

  if cmd_exists rc-service && cmd_exists service; then
    :
  fi

  if cmd_exists mariadb-install-db; then
    $SUDO mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 || true
    return 0
  fi

  if cmd_exists mysql_install_db; then
    $SUDO mysql_install_db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 || true
    return 0
  fi

  if cmd_exists rc-service; then
    $SUDO rc-service mariadb setup >/dev/null 2>&1 || true
  fi

  return 0
}

wait_for_mysql_ready() {
  local retries=30
  local delay=2
  local cli
  cli="$(mysql_detect_cli)"

  if ! cmd_exists "$cli"; then
    return 1
  fi

  local i
  for i in $(seq 1 "$retries"); do
    if $SUDO "$cli" -e "SELECT 1;" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

install_mysql() {
  if is_mysql_installed; then
    local existing_svc
    existing_svc="$(mysql_find_service)"
    if [ -n "$existing_svc" ]; then
      service_enable "$existing_svc"
      service_start "$existing_svc"
    fi
    if ! wait_for_mysql_ready; then
      ui_warn "MySQL/MariaDB is installed but did not respond yet; setup may need the root password prompt."
    fi
    ui_success "MySQL/MariaDB is already installed."
    return 0
  fi

  ui_info "Installing MySQL/MariaDB..."
  if ! ensure_supported_package_manager; then
    ui_error "Could not detect a supported package manager to install MySQL/MariaDB."
    return 1
  fi

  enable_rhel_extra_repos
  ensure_pkg_metadata >/dev/null 2>&1 || true

  case "$PKG_MGR" in
    apt)
      pkg_install_try_sets \
        "mysql-server mysql-client" \
        "default-mysql-server default-mysql-client" \
        "mariadb-server mariadb-client" || return 1
      ;;
    dnf|yum)
      pkg_install_try_sets \
        "mariadb-server mariadb" \
        "mysql-server mysql" \
        "community-mysql-server community-mysql" || return 1
      ;;
    zypper)
      pkg_install_try_sets \
        "mariadb mariadb-client" \
        "mysql mysql-client" || return 1
      ;;
    pacman)
      pkg_install_try_sets \
        "mariadb" || return 1
      ;;
    apk)
      pkg_install_try_sets \
        "mariadb mariadb-client" || return 1
      ;;
    *)
      ui_error "Unsupported package manager for MySQL/MariaDB install."
      return 1
      ;;
  esac

  mysql_init_datadir_if_needed

  local svc
  svc="$(mysql_find_service)"
  if [ -n "$svc" ]; then
    service_enable "$svc"
    service_start "$svc"
  else
    service_enable mariadb
    service_start mariadb
    service_enable mysql
    service_start mysql
  fi

  if is_mysql_installed && wait_for_mysql_ready; then
    ui_success "MySQL/MariaDB installed successfully."
    return 0
  fi

  ui_error "MySQL/MariaDB installation failed or the service did not become ready."
  return 1
}

secure_mariadb_binding() {
  ui_info "Securing MariaDB/MySQL to listen on localhost only..."

  local conf_paths=(
    "/etc/mysql/mariadb.conf.d/50-server.cnf"
    "/etc/mysql/mysql.conf.d/mysqld.cnf"
    "/etc/my.cnf.d/server.cnf"
    "/etc/my.cnf.d/mariadb-server.cnf"
    "/etc/my.cnf"
  )

  local conf_found=""
  for cpath in "${conf_paths[@]}"; do
    if [ -f "$cpath" ]; then
      conf_found="$cpath"
      break
    fi
  done

  if [ -z "$conf_found" ]; then
    # Create a drop-in config if no existing config found
    if [ -d "/etc/mysql/mariadb.conf.d" ]; then
      conf_found="/etc/mysql/mariadb.conf.d/99-adpanel-security.cnf"
    elif [ -d "/etc/mysql/mysql.conf.d" ]; then
      conf_found="/etc/mysql/mysql.conf.d/99-adpanel-security.cnf"
    elif [ -d "/etc/my.cnf.d" ]; then
      conf_found="/etc/my.cnf.d/99-adpanel-security.cnf"
    else
      ui_warn "Could not find MariaDB/MySQL config directory. Skipping bind-address configuration."
      return 1
    fi
    $SUDO tee "$conf_found" >/dev/null <<'BINDEOF'
[mysqld]
bind-address = 127.0.0.1
skip-networking = 0
BINDEOF
    ui_success "Created MariaDB security config at ${conf_found}"
  else
    # Update existing config
    if grep -q "^bind-address" "$conf_found" 2>/dev/null; then
      $SUDO sed -i 's/^bind-address[[:space:]]*=.*/bind-address = 127.0.0.1/' "$conf_found"
    elif grep -q "^#.*bind-address" "$conf_found" 2>/dev/null; then
      $SUDO sed -i 's/^#.*bind-address[[:space:]]*=.*/bind-address = 127.0.0.1/' "$conf_found"
    elif grep -q "^\[mysqld\]" "$conf_found" 2>/dev/null; then
      $SUDO sed -i '/^\[mysqld\]/a bind-address = 127.0.0.1' "$conf_found"
    else
      printf "\n[mysqld]\nbind-address = 127.0.0.1\n" | $SUDO tee -a "$conf_found" >/dev/null
    fi
    ui_success "MariaDB bind-address set to 127.0.0.1 in ${conf_found}"
  fi

  # Restart MariaDB/MySQL to apply
  local svc
  svc="$(mysql_find_service)"
  if [ -n "$svc" ]; then
    service_restart "$svc"
  else
    service_restart mariadb
    service_restart mysql
  fi

  ui_success "MariaDB/MySQL is now listening on localhost only."
  return 0
}

detect_ssh_ports() {
  local found=""
  local file
  for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$file" ] || continue
    found="$found
$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}' "$file" 2>/dev/null || true)"
  done
  found="$(printf "%s\n" "$found" | awk '/^[0-9]+$/ && $1 > 0 && $1 <= 65535 {print $1}' | sort -n -u)"
  if [ -n "$found" ]; then
    printf "%s\n" "$found"
  else
    printf "22\n"
  fi
}

preserve_ssh_firewall_access() {
  local backend="${1:-}"
  local port
  [ -n "$backend" ] || return 0

  case "$backend" in
    ufw)
      while IFS= read -r port; do
        [ -n "$port" ] || continue
        $SUDO ufw allow "${port}/tcp" >/dev/null 2>&1 || true
      done <<EOF
$(detect_ssh_ports)
EOF
      ;;
    firewalld)
      service_enable firewalld >/dev/null 2>&1 || true
      service_start firewalld >/dev/null 2>&1 || true
      $SUDO firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      while IFS= read -r port; do
        [ -n "$port" ] || continue
        $SUDO firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
      done <<EOF
$(detect_ssh_ports)
EOF
      ;;
    iptables)
      while IFS= read -r port; do
        [ -n "$port" ] || continue
        $SUDO iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
          $SUDO iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
      done <<EOF
$(detect_ssh_ports)
EOF
      ;;
    nftables)
      if cmd_exists nft && $SUDO nft list table inet filter >/dev/null 2>&1; then
        while IFS= read -r port; do
          [ -n "$port" ] || continue
          $SUDO nft add rule inet filter input tcp dport "$port" accept >/dev/null 2>&1 || true
        done <<EOF
$(detect_ssh_ports)
EOF
      fi
      ;;
  esac
  return 0
}

harden_firewall() {
  ui_info "Hardening firewall rules..."

  local backend=""

  if cmd_exists ufw; then
    backend="ufw"
  elif cmd_exists firewall-cmd; then
    backend="firewalld"
  else
    ensure_pkg_metadata >/dev/null 2>&1 || true
    case "$PKG_MGR" in
      apt|pacman)
        if pkg_install ufw >/dev/null 2>&1; then
          backend="ufw"
        fi
        ;;
      dnf|yum|zypper)
        if pkg_install firewalld >/dev/null 2>&1; then
          backend="firewalld"
        fi
        ;;
    esac
  fi

  case "$backend" in
    ufw)
      preserve_ssh_firewall_access ufw
      $SUDO ufw deny 445/tcp >/dev/null 2>&1 || true
      $SUDO ufw deny 445/udp >/dev/null 2>&1 || true
      ui_success "Port 445 (SMB) blocked."

      $SUDO ufw deny 3306/tcp >/dev/null 2>&1 || true
      ui_success "Port 3306 (MySQL) blocked from external access."

      if ! $SUDO ufw status | grep -q "Status: active"; then
        $SUDO ufw --force enable >/dev/null 2>&1 || true
      fi
      $SUDO ufw reload >/dev/null 2>&1 || true
      ui_success "Firewall hardened with ufw."
      return 0
      ;;
    firewalld)
      service_enable firewalld
      service_start firewalld
      preserve_ssh_firewall_access firewalld
      $SUDO firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="445" protocol="tcp" reject' >/dev/null 2>&1 || true
      $SUDO firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="445" protocol="udp" reject' >/dev/null 2>&1 || true
      ui_success "Port 445 (SMB) blocked."

      $SUDO firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="3306" protocol="tcp" reject' >/dev/null 2>&1 || true
      ui_success "Port 3306 (MySQL) blocked from external access."

      $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
      ui_success "Firewall hardened with firewalld."
      return 0
      ;;
    *)
      if command -v iptables >/dev/null 2>&1; then
        preserve_ssh_firewall_access iptables
        $SUDO iptables -C INPUT -p tcp --dport 445 -j DROP >/dev/null 2>&1 || \
          $SUDO iptables -A INPUT -p tcp --dport 445 -j DROP >/dev/null 2>&1 || true
        $SUDO iptables -C INPUT -p udp --dport 445 -j DROP >/dev/null 2>&1 || \
          $SUDO iptables -A INPUT -p udp --dport 445 -j DROP >/dev/null 2>&1 || true
        ui_success "Port 445 (SMB) blocked."

        $SUDO iptables -C INPUT -p tcp --dport 3306 -j DROP >/dev/null 2>&1 || \
          $SUDO iptables -A INPUT -p tcp --dport 3306 -j DROP >/dev/null 2>&1 || true
        ui_success "Port 3306 (MySQL) blocked from external access."

        if systemd_available; then
          if systemctl list-unit-files | grep -q "^netfilter-persistent.service"; then
            $SUDO systemctl reload netfilter-persistent >/dev/null 2>&1 || true
          elif systemctl list-unit-files | grep -q "^iptables.service"; then
            $SUDO systemctl reload iptables >/dev/null 2>&1 || true
          fi
        fi
        if command -v service >/dev/null 2>&1; then
          $SUDO service iptables reload >/dev/null 2>&1 || true
        fi
        ui_success "Firewall hardened with iptables."
        return 0
      fi
      ;;
  esac

  ui_warn "No supported firewall manager was found or installed. Skipping firewall hardening."
  return 1
}

is_debian_like_platform() {
  local id_like=" ${OS_LIKE:-} "
  case "${OS_ID:-}" in
    debian|ubuntu|linuxmint|pop|raspbian)
      return 0
      ;;
  esac
  case "$id_like" in
    *" debian "*)
      return 0
      ;;
  esac
  return 1
}

sshd_binary_path() {
  if cmd_exists sshd; then
    command -v sshd
    return 0
  fi
  if [ -x /usr/sbin/sshd ]; then
    printf "%s\n" "/usr/sbin/sshd"
    return 0
  fi
  if [ -x /usr/local/sbin/sshd ]; then
    printf "%s\n" "/usr/local/sbin/sshd"
    return 0
  fi
  return 1
}

sshd_config_is_valid() {
  local sshd_bin
  sshd_bin="$(sshd_binary_path 2>/dev/null || true)"
  [ -n "$sshd_bin" ] || return 0
  $SUDO "$sshd_bin" -t >/dev/null 2>&1
}

reload_sshd_safely() {
  if ! sshd_config_is_valid; then
    ui_warn "OpenSSH config is not valid; not reloading SSH. Existing SSH sessions were left untouched."
    return 1
  fi

  if systemd_available; then
    $SUDO systemctl reload sshd 2>/dev/null || \
      $SUDO systemctl reload ssh 2>/dev/null || \
      service_reload sshd 2>/dev/null || \
      service_reload ssh 2>/dev/null || true
  else
    service_reload sshd 2>/dev/null || service_reload ssh 2>/dev/null || true
  fi
  return 0
}

repair_openssh_cross_distro_config() {
  local changed=false
  local file

  # DebianBanner is a Debian/Ubuntu OpenSSH patch. RHEL/Rocky/OpenSSH Portable
  # treats it as a fatal config error, so never write it and repair old ADPanel
  # installs that did.
  if is_debian_like_platform; then
    return 0
  fi

  for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$file" ] || continue
    if grep -qE '^[[:space:]]*DebianBanner([[:space:]]|$)' "$file" 2>/dev/null; then
      $SUDO cp -a "$file" "${file}.adpanel-bak.$(date +%Y%m%d%H%M%S)" >/dev/null 2>&1 || true
      $SUDO sed -i -E '/^[[:space:]]*DebianBanner([[:space:]]|$)/ s/^/# ADPanel disabled non-portable OpenSSH option: /' "$file"
      changed=true
      ui_warn "Disabled unsupported DebianBanner in ${file}; Rocky/RHEL sshd rejects this option."
    fi
  done

  if [ "$changed" = true ]; then
    if reload_sshd_safely; then
      ui_success "OpenSSH config repaired and reloaded safely."
    else
      ui_warn "OpenSSH config was repaired, but sshd -t still fails; inspect /etc/ssh/sshd_config before restarting SSH."
    fi
  fi
}

mask_service_versions() {
  ui_info "Masking service version fingerprints..."

  # --- Nginx: hide version in Server header globally ---
  if [ -f /etc/nginx/nginx.conf ]; then
    if ! grep -qE "^[[:space:]]*server_tokens[[:space:]]+off" /etc/nginx/nginx.conf 2>/dev/null; then
      if grep -qE "^[[:space:]]*http[[:space:]]*\\{" /etc/nginx/nginx.conf 2>/dev/null; then
        $SUDO sed -i '/^[[:space:]]*http[[:space:]]*{/a\    server_tokens off;' /etc/nginx/nginx.conf
      else
        # Fallback: append in http block area
        $SUDO sed -i '/^[[:space:]]*include.*sites-enabled/i\    server_tokens off;' /etc/nginx/nginx.conf 2>/dev/null || true
      fi
      ui_success "Nginx server_tokens off added."
    else
      ui_info "Nginx server_tokens already disabled."
    fi
  fi

  # --- MariaDB/MySQL: remove version comment ---
  local mysql_conf_dirs=(
    "/etc/mysql/mariadb.conf.d"
    "/etc/mysql/mysql.conf.d"
    "/etc/my.cnf.d"
  )
  local mysql_hardened=false
  for confdir in "${mysql_conf_dirs[@]}"; do
    if [ -d "$confdir" ]; then
      local target="${confdir}/99-adpanel-version-mask.cnf"
      $SUDO tee "$target" >/dev/null <<'MYSQLEOF'
[mysqld]
performance_schema = OFF
MYSQLEOF
      ui_success "MariaDB/MySQL hardened in ${target}"
      mysql_hardened=true
      break
    fi
  done
  if [ "$mysql_hardened" = false ] && [ -f /etc/my.cnf ]; then
    if ! grep -q "performance_schema" /etc/my.cnf 2>/dev/null; then
      if grep -q "^\[mysqld\]" /etc/my.cnf 2>/dev/null; then
        $SUDO sed -i '/^\[mysqld\]/a performance_schema = OFF' /etc/my.cnf
      else
        printf "\n[mysqld]\nperformance_schema = OFF\n" | $SUDO tee -a /etc/my.cnf >/dev/null
      fi
      ui_success "MariaDB/MySQL hardened in /etc/my.cnf"
    fi
  fi

  repair_openssh_cross_distro_config

  # --- PHP: hide version from HTTP headers (for phpMyAdmin) ---
  local php_ini_paths=(
    "/etc/php/8.3/fpm/php.ini"
    "/etc/php/8.2/fpm/php.ini"
    "/etc/php/8.1/fpm/php.ini"
    "/etc/php/8.0/fpm/php.ini"
    "/etc/php/7.4/fpm/php.ini"
  )
  for pini in "${php_ini_paths[@]}"; do
    if [ -f "$pini" ]; then
      if grep -qE "^expose_php[[:space:]]*=[[:space:]]*On" "$pini" 2>/dev/null; then
        $SUDO sed -i 's/^expose_php[[:space:]]*=[[:space:]]*On/expose_php = Off/' "$pini"
        ui_success "PHP expose_php disabled in ${pini}"
      elif ! grep -q "^expose_php" "$pini" 2>/dev/null; then
        echo "expose_php = Off" | $SUDO tee -a "$pini" >/dev/null
        ui_success "PHP expose_php disabled in ${pini}"
      fi
    fi
  done
  # Restart PHP-FPM if running
  local php_fpm_svc=""
  if systemd_available; then
    php_fpm_svc=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^php[0-9.]+-fpm\.service$' | sort -r | head -1)
    if [ -n "$php_fpm_svc" ]; then
      $SUDO systemctl restart "$php_fpm_svc" 2>/dev/null || true
    fi
  fi

  # --- Apache: hide version (for pgAdmin4) ---
  if [ -f /etc/apache2/apache2.conf ]; then
    local apache_hardened=false
    # ServerTokens Prod
    if ! grep -qE "^ServerTokens[[:space:]]+Prod" /etc/apache2/apache2.conf 2>/dev/null; then
      if grep -q "^ServerTokens" /etc/apache2/apache2.conf 2>/dev/null; then
        $SUDO sed -i 's/^ServerTokens.*/ServerTokens Prod/' /etc/apache2/apache2.conf
      else
        echo "ServerTokens Prod" | $SUDO tee -a /etc/apache2/apache2.conf >/dev/null
      fi
      apache_hardened=true
    fi
    # ServerSignature Off
    if ! grep -qE "^ServerSignature[[:space:]]+Off" /etc/apache2/apache2.conf 2>/dev/null; then
      if grep -q "^ServerSignature" /etc/apache2/apache2.conf 2>/dev/null; then
        $SUDO sed -i 's/^ServerSignature.*/ServerSignature Off/' /etc/apache2/apache2.conf
      else
        echo "ServerSignature Off" | $SUDO tee -a /etc/apache2/apache2.conf >/dev/null
      fi
      apache_hardened=true
    fi
    # Ensure headers module is enabled for Header directives
    $SUDO a2enmod headers 2>/dev/null || true
    if [ "$apache_hardened" = true ]; then
      service_restart apache2 2>/dev/null || true
      ui_success "Apache version fingerprint masked."
    else
      ui_info "Apache version already masked."
    fi
  fi

  # --- PostgreSQL: restrict version exposure ---
  local pg_conf_found=false
  for pgconf in $(find /etc/postgresql -name postgresql.conf 2>/dev/null); do
    if [ -f "$pgconf" ]; then
      # Disable server version in error messages to unauthenticated clients
      if ! grep -qE "^password_encryption[[:space:]]*=[[:space:]]*scram-sha-256" "$pgconf" 2>/dev/null; then
        if grep -q "^#\?password_encryption" "$pgconf" 2>/dev/null; then
          $SUDO sed -i "s/^#\?password_encryption.*/password_encryption = scram-sha-256/" "$pgconf"
        else
          echo "password_encryption = scram-sha-256" | $SUDO tee -a "$pgconf" >/dev/null
        fi
      fi
      if ! grep -qE "^log_hostname[[:space:]]*=[[:space:]]*off" "$pgconf" 2>/dev/null; then
        if grep -q "^#\?log_hostname" "$pgconf" 2>/dev/null; then
          $SUDO sed -i "s/^#\?log_hostname.*/log_hostname = off/" "$pgconf"
        else
          echo "log_hostname = off" | $SUDO tee -a "$pgconf" >/dev/null
        fi
      fi
      pg_conf_found=true
    fi
  done
  if [ "$pg_conf_found" = true ]; then
    service_reload postgresql 2>/dev/null || true
    ui_success "PostgreSQL hardened."
  fi

  # --- MongoDB: reduce fingerprint exposure ---
  if [ -f /etc/mongod.conf ]; then
    # Ensure quiet mode is enabled to reduce protocol-level information leakage
    if ! grep -qE "^[[:space:]]*quiet:[[:space:]]*true" /etc/mongod.conf 2>/dev/null; then
      if grep -q "^systemLog:" /etc/mongod.conf 2>/dev/null; then
        $SUDO sed -i '/^systemLog:/a\  quiet: true' /etc/mongod.conf
      fi
      service_restart mongod 2>/dev/null || true
      ui_success "MongoDB fingerprint exposure reduced."
    else
      ui_info "MongoDB quiet mode already enabled."
    fi
  fi

  ui_success "Service version fingerprints masked."
  return 0
}

mysql_sql_escape() {
  printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"
}

mysql_exec_as_root() {
  local sql="$1"
  local root_pass="${2:-}"
  local cli
  cli="$(mysql_detect_cli)"

  if ! cmd_exists "$cli"; then
    return 1
  fi

  if $SUDO "$cli" -e "$sql" >/dev/null 2>&1; then
    return 0
  fi

  if [ -n "$root_pass" ]; then
    if "$cli" -uroot -p"$root_pass" -h 127.0.0.1 -e "$sql" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

prompt_mysql_password() {
  local p=""
  while true; do
    read -r -s -p "$(ui_prompt "Enter MySQL password for the new user: ")" p
    printf '\n' >&2
    if [ -z "$p" ]; then
      p="$(generate_base64url_token 32)"
      ui_info "Generated a strong MySQL password automatically." >&2
      printf '%s' "$p"
      return 0
    fi
    if printf '%s' "$p" | grep -qE '[[:space:]]'; then
      ui_error "MySQL password cannot contain spaces or newlines." >&2
      continue
    fi
    printf '%s' "$p"
    return 0
  done
}

setup_mysql() {
  MYSQL_HOST="127.0.0.1"
  MYSQL_PORT="3306"
  MYSQL_USER="adpanel"
  MYSQL_PASSWORD=""
  MYSQL_DATABASE="adpanel"
  MYSQL_URL=""

  ui_section "=== MySQL/MariaDB configuration (users/storage) ==="
  read -p "$(ui_prompt "Do you want to configure MySQL/MariaDB now? (yes/no, default yes): ")" USE_MYSQL
  USE_MYSQL="$(lower_trim "$USE_MYSQL")"
  if [ -n "$USE_MYSQL" ] && [ "$USE_MYSQL" != "yes" ] && [ "$USE_MYSQL" != "y" ]; then
    ui_warn "Skipping MySQL/MariaDB setup; leaving MYSQL_* empty in .env."
    MYSQL_HOST=""
    MYSQL_PORT=""
    MYSQL_USER=""
    MYSQL_PASSWORD=""
    MYSQL_DATABASE=""
    MYSQL_URL=""
    return 0
  fi

  if ! install_mysql; then
    ui_warn "MySQL/MariaDB install failed; leaving MYSQL_* empty in .env."
    MYSQL_HOST=""
    MYSQL_PORT=""
    MYSQL_USER=""
    MYSQL_PASSWORD=""
    MYSQL_DATABASE=""
    MYSQL_URL=""
    return 1
  fi

  read -p "$(ui_prompt "MySQL host (default 127.0.0.1): ")" MYSQL_HOST_IN
  MYSQL_HOST_IN="$(trim_ws "$MYSQL_HOST_IN")"
  if [ -n "$MYSQL_HOST_IN" ]; then
    MYSQL_HOST="$MYSQL_HOST_IN"
  fi

  read -p "$(ui_prompt "MySQL port (default 3306): ")" MYSQL_PORT_IN
  MYSQL_PORT_IN="$(trim_ws "$MYSQL_PORT_IN")"
  if [ -n "$MYSQL_PORT_IN" ]; then
    MYSQL_PORT="$(normalize_port "$MYSQL_PORT_IN" 3306)"
  fi

  read -p "$(ui_prompt "MySQL database name (default adpanel): ")" MYSQL_DB_IN
  MYSQL_DB_IN="$(trim_ws "$MYSQL_DB_IN")"
  if [ -n "$MYSQL_DB_IN" ]; then
    MYSQL_DATABASE="$MYSQL_DB_IN"
  fi

  read -p "$(ui_prompt "MySQL username (default adpanel): ")" MYSQL_USER_IN
  MYSQL_USER_IN="$(trim_ws "$MYSQL_USER_IN")"
  if [ -n "$MYSQL_USER_IN" ]; then
    MYSQL_USER="$MYSQL_USER_IN"
  fi

  MYSQL_PASSWORD="$(prompt_mysql_password)"

  ui_info "MySQL settings chosen:"
  ui_kv "  USERNAME:" "${MYSQL_USER}"
  ui_kv "  HOST:" "${MYSQL_HOST}"
  ui_kv "  PORT:" "${MYSQL_PORT}"
  ui_kv "  PASSWORD:" "${MYSQL_PASSWORD}"
  ui_kv "  DATABASE:" "${MYSQL_DATABASE}"

  local esc_user esc_pass esc_db
  esc_user="$(mysql_sql_escape "$MYSQL_USER")"
  esc_pass="$(mysql_sql_escape "$MYSQL_PASSWORD")"
  esc_db="$(printf "%s" "$MYSQL_DATABASE" | sed "s/\`//g")"

  if ! printf "%s" "$esc_user" | grep -qE '^[A-Za-z0-9_@.-]+$'; then
    ui_warn "MySQL username contains unsupported characters; skipping automatic user creation."
  elif ! printf "%s" "$esc_db" | grep -qE '^[A-Za-z0-9_]+$'; then
    ui_warn "MySQL database name contains unsupported characters; skipping automatic DB creation."
  else
    local sql
    sql=$(cat <<EOF
CREATE DATABASE IF NOT EXISTS \`$esc_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '$esc_user'@'localhost' IDENTIFIED BY '$esc_pass';
CREATE USER IF NOT EXISTS '$esc_user'@'127.0.0.1' IDENTIFIED BY '$esc_pass';
ALTER USER '$esc_user'@'localhost' IDENTIFIED BY '$esc_pass';
ALTER USER '$esc_user'@'127.0.0.1' IDENTIFIED BY '$esc_pass';

-- Schema permissions kept local-only; REFERENCES is needed for foreign keys.
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES
ON \`$esc_db\`.*
TO '$esc_user'@'localhost';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES
ON \`$esc_db\`.*
TO '$esc_user'@'127.0.0.1';

FLUSH PRIVILEGES;
EOF
)
    if ! mysql_exec_as_root "$sql"; then
      ui_warn "Could not configure MySQL via root socket auth."
      read -s -p "$(ui_prompt "If your MySQL root user has a password, enter it now (or press Enter to skip DB/user creation): ")" MYSQL_ROOT_PASS
      echo ""
      if [ -n "$MYSQL_ROOT_PASS" ]; then
        if ! mysql_exec_as_root "$sql" "$MYSQL_ROOT_PASS"; then
          ui_warn "Still could not create DB/user automatically. You may need to create them manually."
        else
          ui_success "MySQL database/user configured successfully."
        fi
      else
        ui_warn "Skipping automatic DB/user creation."
      fi
    else
      ui_success "MySQL database/user configured successfully."
    fi
  fi

  local encoded_pass
  encoded_pass=$(node -e "console.log(encodeURIComponent(process.argv[1] || ''))" "$MYSQL_PASSWORD")
  MYSQL_URL="mysql://${MYSQL_USER}:${encoded_pass}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
  return 0
}

wait_for_mysql_table() {
  local db="$1"
  local table="$2"
  local host="$3"
  local port="$4"
  local user="$5"
  local pass="$6"
  local retries=40
  local delay=2
  local max_wait=$((retries * delay))

  if [ -z "$db" ] || [ -z "$table" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$user" ]; then
    return 1
  fi

  local cli
  cli="$(mysql_detect_cli)"
  if ! cmd_exists "$cli"; then
    return 1
  fi

  ui_info "Waiting for MySQL table ${db}.${table} to be created (up to ${max_wait}s)..."
  for i in $(seq 1 "$retries"); do
    local out=""
    if [ -n "$pass" ]; then
      out=$(MYSQL_PWD="$pass" "$cli" -h "$host" -P "$port" -u "$user" -Nse \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='${table}';" 2>/dev/null || true)
    else
      out=$("$cli" -h "$host" -P "$port" -u "$user" -Nse \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='${table}';" 2>/dev/null || true)
    fi

    if [ "$out" == "1" ] || [ "$out" -gt 0 ] 2>/dev/null; then
      ui_success "MySQL table ${db}.${table} is ready."
      return 0
    fi

    printf "."
    sleep "$delay"
  done

  echo ""
  return 1
}

bootstrap_db_and_create_admin() {
  local admin_email="$1"
  local admin_hash="$2"
  local admin_secret="$3"
  local admin_avatar_url=""

  admin_avatar_url="$(pick_default_avatar_url admin)"

  if [ -z "$MYSQL_URL" ] || [ -z "$MYSQL_DATABASE" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
    return 0
  fi

  if [ -z "$admin_email" ] || [ -z "$admin_hash" ]; then
    return 0
  fi

  local script_path="$CREATE_USER_SCRIPT"
  if [ -z "$script_path" ]; then
    ui_warn "create-user.js not found (expected ${PANEL_ROOT}/scripts/create-user.js); skipping automatic admin DB seeding."
    return 0
  fi

  ui_info "Bootstrapping database schema via: npm start"
  local boot_log="/tmp/adpanel-npm-start-bootstrap.log"
  local pid=""

  if cmd_exists timeout; then
    timeout 90s npm start >"$boot_log" 2>&1 &
    pid=$!
  else
    npm start >"$boot_log" 2>&1 &
    pid=$!
  fi

  if ! wait_for_mysql_table "$MYSQL_DATABASE" "users" "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD"; then
    ui_warn "users table did not appear. Check bootstrap log: ${boot_log}"
  fi

  if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 2
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  ui_info "Seeding admin user via ${script_path}..."

  if [ -n "$admin_secret" ]; then
    $SUDO node "$script_path" --email "$admin_email" --password-hash "$admin_hash" --admin --secret "$admin_secret" --avatar-url "$admin_avatar_url"
  else
    $SUDO node "$script_path" --email "$admin_email" --password-hash "$admin_hash" --admin --avatar-url "$admin_avatar_url"
  fi

  return $?
}


install_redis() {
  if is_redis_installed; then
    ui_success "Redis (or compatible) is already installed."
    detect_redis_commands
    return 0
  fi

  ui_info "Installing Redis (This may take a few minutes)..."
  if ! ensure_supported_package_manager; then
    ui_error "Could not detect a supported package manager to install Redis."
    return 1
  fi

  enable_rhel_extra_repos
  ensure_pkg_metadata >/dev/null 2>&1 || true

  case "$PKG_MGR" in
    apt)
      pkg_install_try_sets \
        "redis-server redis-tools" \
        "redis-server" \
        "valkey-redis-compat" \
        "valkey valkey-tools" \
        "valkey-server valkey-tools" || return 1
      ;;
    dnf|yum)
      enable_rhel_redis_module_if_available
      ensure_pkg_metadata >/dev/null 2>&1 || true
      if ! pkg_install_try_sets \
        "redis" \
        "redis6" \
        "redis7" \
        "redis-server" \
        "valkey" \
        "valkey valkey-compat" \
        "valkey-redis-compat"; then
        install_redis_from_official_rpm_repo || return 1
      fi
      ;;
    zypper)
      pkg_install_try_sets \
        "redis" \
        "valkey" \
        "valkey-redis-compat" || return 1
      ;;
    apk|pacman)
      pkg_install_try_sets \
        "redis" \
        "valkey" \
        "valkey-redis-compat" || return 1
      ;;
    *)
      ui_error "Unsupported package manager for Redis install."
      return 1
      ;;
  esac

  detect_redis_commands

  if is_redis_installed; then
    ui_success "Redis installed successfully."
    return 0
  fi

  ui_error "Redis installation failed."
  return 1
}

detect_redis_conf() {
  local candidates=(
    "/etc/redis/redis.conf"
    "/etc/redis/default.conf"
    "/etc/redis.conf"
    "/usr/local/etc/redis/redis.conf"
    "/etc/valkey/valkey.conf"
    "/etc/valkey/default.conf"
    "/etc/valkey.conf"
  )
  for f in "${candidates[@]}"; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done
  echo ""
  return 1
}

calculate_redis_maxmemory() {
  local mem_kb=""
  if [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo | head -n1)
  fi

  if [ -n "$mem_kb" ]; then
    local mem_mb=$((mem_kb / 1024))
    local mm_mb=$((mem_mb / 4))
    if [ "$mm_mb" -lt 64 ]; then mm_mb=64; fi
    if [ "$mm_mb" -gt 2048 ]; then mm_mb=2048; fi
    echo "${mm_mb}mb"
    return 0
  fi

  echo "256mb"
  return 0
}

redis_bind_line() {
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
    local disabled
    disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    if [ "$disabled" == "0" ]; then
      echo "bind 127.0.0.1 ::1"
      return 0
    fi
  fi
  echo "bind 127.0.0.1"
  return 0
}

redis_supervised_value() {
  if [ "$INIT_SYSTEM" == "systemd" ]; then
    echo "systemd"
  else
    echo "no"
  fi
}

redis_can_enable_activedefrag() {
  detect_redis_commands
  if ! cmd_exists "$REDIS_SERVER_CMD"; then
    return 1
  fi
  if ! cmd_exists timeout; then
    return 1
  fi

  local tmp
  tmp="$(mktemp /tmp/adpanel-redis-probe.XXXXXX.conf 2>/dev/null || echo "")"
  if [ -z "$tmp" ]; then
    return 1
  fi

  cat > "$tmp" <<'EOF'
port 0
bind 127.0.0.1
protected-mode yes
daemonize no
save ""
appendonly no
activedefrag yes
EOF

  local out rc
  out="$(timeout 1 "$REDIS_SERVER_CMD" "$tmp" 2>&1 || true)"
  rc=$?

  rm -f "$tmp" >/dev/null 2>&1 || true

  if echo "$out" | grep -qi "Active defragmentation cannot be enabled"; then
    return 1
  fi
  if echo "$out" | grep -qi "FATAL CONFIG FILE ERROR"; then
    return 1
  fi

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
    return 0
  fi

  return 1
}

configure_redis_auth() {
  local conf="$1"
  local password="$2"
  if [ -z "$conf" ] || [ -z "$password" ]; then
    return 1
  fi

  $SUDO sed -i '/^[[:space:]]*# === ADPANEL REDIS SETTINGS START ===$/,/^[[:space:]]*# === ADPANEL REDIS SETTINGS END ===$/d' "$conf" 2>/dev/null || true

  $SUDO sed -i '/^[[:space:]]*requirepass[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*bind[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*protected-mode[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*supervised[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*save[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*appendonly[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*appendfsync[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*no-appendfsync-on-rewrite[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*aof-use-rdb-preamble[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*maxmemory[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*maxmemory-policy[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*lazyfree-lazy-eviction[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*lazyfree-lazy-expire[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*lazyfree-lazy-server-del[[:space:]]/d' "$conf" 2>/dev/null || true
  $SUDO sed -i '/^[[:space:]]*activedefrag[[:space:]]/d' "$conf" 2>/dev/null || true

  local maxmemory
  maxmemory=$(calculate_redis_maxmemory)

  local bindline
  bindline=$(redis_bind_line)

  local supervised_val
  supervised_val=$(redis_supervised_value)

  local enable_activedefrag="no"
  if redis_can_enable_activedefrag; then
    enable_activedefrag="yes"
  fi

  cat <<EOF | $SUDO tee -a "$conf" >/dev/null
${bindline}
protected-mode yes
supervised ${supervised_val}

requirepass ${password}

save 900 1 300 10 60 10000
appendonly yes
appendfsync everysec
no-appendfsync-on-rewrite no
aof-use-rdb-preamble yes

maxmemory ${maxmemory}
maxmemory-policy noeviction

lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
EOF

  if [ "$enable_activedefrag" == "yes" ]; then
    echo "activedefrag yes" | $SUDO tee -a "$conf" >/dev/null
  else
    cat <<'EOF' | $SUDO tee -a "$conf" >/dev/null
EOF
  fi

  cat <<EOF | $SUDO tee -a "$conf" >/dev/null
EOF

  local acl_file
  acl_file=$(grep -E '^[[:space:]]*aclfile[[:space:]]+' "$conf" | awk '{print $2}' | tail -n 1)
  if [ -z "$acl_file" ] && [ -f "/etc/redis/users.acl" ]; then
    acl_file="/etc/redis/users.acl"
  fi

  if [ -n "$acl_file" ]; then
    $SUDO mkdir -p "$(dirname "$acl_file")" >/dev/null 2>&1 || true
    $SUDO sed -i "/^[[:space:]]*user[[:space:]]\\+default[[:space:]]\\+/d" "$acl_file" 2>/dev/null || true
    echo "user default on >${password} ~* +@all" | $SUDO tee -a "$acl_file" >/dev/null
  fi
}

ensure_overcommit_memory() {
  cmd_exists sysctl || return 0
  $SUDO sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
  if [ -f /etc/sysctl.conf ]; then
    if grep -qE '^[[:space:]]*vm\.overcommit_memory' /etc/sysctl.conf; then
      $SUDO sed -i "s|^[[:space:]]*vm\.overcommit_memory[[:space:]]*=.*|vm.overcommit_memory = 1|g" /etc/sysctl.conf
    else
      echo "vm.overcommit_memory = 1" | $SUDO tee -a /etc/sysctl.conf >/dev/null
    fi
  fi
}

restart_redis_service() {
  local svc=""

  if [ "$INIT_SYSTEM" == "systemd" ]; then
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    local unit_files=""
    unit_files="$(systemctl list-unit-files 2>/dev/null || true)"
    if printf "%s\n" "$unit_files" | grep -q "^redis-server.service"; then
      svc="redis-server"
    elif printf "%s\n" "$unit_files" | grep -q "^redis.service"; then
      svc="redis"
    elif printf "%s\n" "$unit_files" | grep -q "^redis@.service"; then
      svc="redis@default"
    elif printf "%s\n" "$unit_files" | grep -q "^valkey.service"; then
      svc="valkey"
    elif printf "%s\n" "$unit_files" | grep -q "^valkey-server.service"; then
      svc="valkey-server"
    elif printf "%s\n" "$unit_files" | grep -q "^valkey@.service"; then
      svc="valkey@default"
    fi

    if [ -n "$svc" ]; then
      $SUDO systemctl reset-failed "$svc" >/dev/null 2>&1 || true
      service_enable "$svc"
      service_restart "$svc"
      return 0
    fi
  fi

  for svc in redis-server redis redis@default valkey valkey-server valkey@default; do
    service_restart "$svc"
  done

  return 0
}

configure_redis_firewall() {
  ui_info "Redis stays bound to localhost only; skipping automatic firewall changes for port 6379."
}

wait_for_redis() {
  local host="$1"
  local port="$2"
  local pass="$3"
  local retries=10
  local delay=2
  local max_wait=$((retries * delay))

  detect_redis_commands
  if ! command -v "$REDIS_CLI_CMD" >/dev/null 2>&1; then
    return 1
  fi

  ui_info "Waiting for Redis to accept connections (up to ${max_wait}s)..."

  for i in $(seq 1 "$retries"); do
    local out
    if command -v timeout >/dev/null 2>&1; then
      out=$(timeout 2 "$REDIS_CLI_CMD" -h "$host" -p "$port" -a "$pass" --no-auth-warning ping 2>/dev/null || true)
    else
      out=$("$REDIS_CLI_CMD" -h "$host" -p "$port" -a "$pass" --no-auth-warning ping 2>/dev/null || true)
    fi
    if [ "$out" == "PONG" ]; then
      ui_success "Redis is ready."
      return 0
    fi
    printf "."
    sleep "$delay"
  done

  echo ""
  return 1
}

prompt_redis_password() {
  local pass1=""
  while true; do
    read -r -s -p "$(ui_prompt "Enter Redis password: ")" pass1
    printf '\n' >&2

    if [ -z "$pass1" ]; then
      pass1="$(generate_base64url_token 32)"
      ui_info "Generated a strong Redis password automatically." >&2
      printf '%s' "$pass1"
      return 0
    fi
    if printf '%s' "$pass1" | grep -qE '[[:space:]]'; then
      ui_error "Redis password cannot contain spaces or newlines." >&2
      continue
    fi

    printf '%s' "$pass1"
    return 0
  done
}

setup_redis() {
  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_USER="default"
  REDIS_PASSWORD=""
  REDIS_URL=""
  SESSION_STORE="file"

  read -p "$(ui_prompt "Do you want to configure Redis (with password) for session storage? (yes/no, default yes): ")" USE_REDIS
  USE_REDIS="$(lower_trim "$USE_REDIS")"
  if [ -z "$USE_REDIS" ] || [ "$USE_REDIS" == "yes" ] || [ "$USE_REDIS" == "y" ]; then
    :
  else
    ui_warn "Skipping Redis setup; using file sessions."
    SESSION_STORE="file"
    REDIS_PASSWORD=""
    REDIS_URL=""
    return 0
  fi

  if ! install_redis; then
    ui_warn "Redis installation failed; falling back to file sessions."
    SESSION_STORE="file"
    REDIS_PASSWORD=""
    REDIS_URL=""
    return 1
  fi

  if ! is_redis_installed; then
    ui_warn "Redis not detected after install; falling back to file sessions."
    SESSION_STORE="file"
    REDIS_PASSWORD=""
    REDIS_URL=""
    return 1
  fi

  detect_redis_commands

  REDIS_PASSWORD="$(prompt_redis_password)"
  local conf
  conf=$(detect_redis_conf)
  if [ -z "$conf" ]; then
    ui_warn "Redis config not found; skipping config changes."
  else
    configure_redis_auth "$conf" "$REDIS_PASSWORD"
  fi

  ensure_overcommit_memory
  ui_info "Restarting Redis..."
  restart_redis_service
  configure_redis_firewall

  local encoded_pass
  encoded_pass=$(node -e "console.log(encodeURIComponent(process.argv[1] || ''))" "$REDIS_PASSWORD")
  REDIS_URL="redis://${REDIS_USER}:${encoded_pass}@${REDIS_HOST}:${REDIS_PORT}"
  SESSION_STORE="redis"

  if ! wait_for_redis "$REDIS_HOST" "$REDIS_PORT" "$REDIS_PASSWORD"; then
    ui_warn "Redis did not respond to PING; falling back to file sessions."
    SESSION_STORE="file"
    REDIS_URL=""
    REDIS_PASSWORD=""
    return 1
  fi
}

detect_nginx_layout() {
  if [ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ]; then
    echo "debian"
  else
    echo "confd"
  fi
}

detect_nginx_user() {
  local nginx_user=""

  if [ -f /etc/nginx/nginx.conf ]; then
    nginx_user=$(grep -E "^[[:space:]]*user[[:space:]]+" /etc/nginx/nginx.conf 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
  fi

  if [ -z "$nginx_user" ]; then
    if id "www-data" >/dev/null 2>&1; then
      nginx_user="www-data"
    elif id "nginx" >/dev/null 2>&1; then
      nginx_user="nginx"
    elif id "http" >/dev/null 2>&1; then
      nginx_user="http"
    elif id "nobody" >/dev/null 2>&1; then
      nginx_user="nobody"
    fi
  fi

  echo "$nginx_user"
}

fix_nginx_static_permissions() {
  local panel_root="$1"
  local static_root="${panel_root}/public"
  local nginx_user
  nginx_user="$(detect_nginx_user)"

  ui_info "Setting permissions for nginx to serve static files..."

  if [ -z "$nginx_user" ]; then
    ui_warn "Warning: Could not detect nginx user. Using world-readable permissions."
    $SUDO chmod -R o+r "$static_root" 2>/dev/null || true
    $SUDO find "$static_root" -type d -exec chmod o+rx {} \; 2>/dev/null || true
  else
    ui_success "Detected nginx user: ${nginx_user}"
    $SUDO chmod -R o+r "$static_root" 2>/dev/null || true
    $SUDO find "$static_root" -type d -exec chmod o+rx {} \; 2>/dev/null || true
  fi

  local current_dir="$panel_root"
  while [ "$current_dir" != "/" ] && [ -n "$current_dir" ]; do
    $SUDO chmod o+x "$current_dir" 2>/dev/null || true
    current_dir="$(dirname "$current_dir")"
  done

  ui_success "Permissions set successfully."
}

generate_base64url_token() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$bytes" | tr '+/' '-_' | tr -d '=\n'
  else
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

ensure_stealth_config() {
  local panel_root="$1"
  local stealth_dir="${panel_root}/data"
  local stealth_path="${stealth_dir}/stealth.json"

  if [ -s "$stealth_path" ]; then
    ui_info "Stealth config already present."
    return 0
  fi

  local created_at
  local cookie_secret
  local challenge_secret
  local html_variant_salt

  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cookie_secret="$(generate_base64url_token 48)"
  challenge_secret="$(generate_base64url_token 48)"
  html_variant_salt="$(generate_base64url_token 24)"

  $SUDO mkdir -p "$stealth_dir"
  cat <<EOF | $SUDO tee "$stealth_path" >/dev/null
{
  "enabled": true,
  "cookieName": "adpanel_gate",
  "cookieSecret": "${cookie_secret}",
  "cookieTtlDays": 30,
  "challengeSecret": "${challenge_secret}",
  "htmlVariantSalt": "${html_variant_salt}",
  "createdAt": "${created_at}",
  "rotatedAt": "${created_at}"
}
EOF
  $SUDO chmod 600 "$stealth_path" 2>/dev/null || true
  ui_success "Generated stealth config."
}

backup_path_for_restore() {
  local source="$1"
  local dest_base="$2"

  if [ -L "$source" ]; then
    readlink "$source" > "${dest_base}.symlink" 2>/dev/null || true
  elif [ -e "$source" ]; then
    $SUDO cp -a "$source" "${dest_base}.file" >/dev/null 2>&1 || true
  else
    : > "${dest_base}.missing"
  fi
}

restore_path_from_backup() {
  local target="$1"
  local dest_base="$2"

  if [ -f "${dest_base}.symlink" ]; then
    local link_target
    link_target="$(cat "${dest_base}.symlink" 2>/dev/null || true)"
    $SUDO rm -f "$target" >/dev/null 2>&1 || true
    if [ -n "$link_target" ]; then
      $SUDO ln -s "$link_target" "$target" >/dev/null 2>&1 || true
    fi
  elif [ -e "${dest_base}.file" ]; then
    $SUDO rm -rf "$target" >/dev/null 2>&1 || true
    $SUDO cp -a "${dest_base}.file" "$target" >/dev/null 2>&1 || true
  elif [ -f "${dest_base}.missing" ]; then
    $SUDO rm -rf "$target" >/dev/null 2>&1 || true
  fi
}

write_nginx_config() {
  local server_name="${NGINX_SERVER_NAME:-$HOST}"
  server_name="$(trim_ws "$server_name")"
  if [ -z "$server_name" ] || [ "$server_name" == "0.0.0.0" ] || [ "$server_name" == "127.0.0.1" ] || [ "$server_name" == "localhost" ]; then
    server_name="_"
  fi

  # Detect nginx brotli module availability
  local nginx_has_brotli="false"
  if nginx -V 2>&1 | grep -q 'brotli' || find /etc/nginx/modules-enabled /usr/share/nginx/modules -maxdepth 1 -name '*brotli*' -print -quit 2>/dev/null | grep -q .; then
    nginx_has_brotli="true"
  fi
  # Try to install brotli module if not present
  if [ "$nginx_has_brotli" == "false" ]; then
    if install_optional_nginx_brotli_module >/dev/null 2>&1; then
      nginx_has_brotli="true"
      ui_success "nginx brotli module installed."
    fi
  fi
  if [ "$nginx_has_brotli" == "true" ]; then
    ui_info "nginx brotli compression: enabled"
  else
    ui_info "nginx brotli compression: not available (using gzip only)"
  fi

  local upstream_host="${APP_HOST}"
  local upstream_port="${APP_PORT}"
  local panel_root="$PANEL_ROOT"
  local static_root="${panel_root}/public"

  local layout
  layout="$(detect_nginx_layout)"

  local config_path=""
  local ssl_config_path=""

  if [ "$layout" == "debian" ]; then
    config_path="/etc/nginx/sites-available/adpanel.conf"
    ssl_config_path="/etc/nginx/sites-available/adpanel-ssl.conf"
    $SUDO mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled >/dev/null 2>&1 || true
  else
    config_path="/etc/nginx/conf.d/adpanel.conf"
    ssl_config_path="/etc/nginx/conf.d/adpanel-ssl.conf"
    $SUDO mkdir -p /etc/nginx/conf.d >/dev/null 2>&1 || true
  fi

  local backup_dir
  backup_dir="$(mktemp -d /tmp/adpanel-nginx.XXXXXX 2>/dev/null || mktemp -d)"
  backup_path_for_restore "$config_path" "${backup_dir}/adpanel.conf"
  backup_path_for_restore "$ssl_config_path" "${backup_dir}/adpanel-ssl.conf"
  backup_path_for_restore "/etc/nginx/sites-enabled/adpanel.conf" "${backup_dir}/enabled-adpanel.conf"
  backup_path_for_restore "/etc/nginx/sites-enabled/adpanel-ssl.conf" "${backup_dir}/enabled-adpanel-ssl.conf"
  backup_path_for_restore "/etc/nginx/sites-enabled/default" "${backup_dir}/enabled-default"
  backup_path_for_restore "/etc/nginx/conf.d/adpanel-performance.conf" "${backup_dir}/adpanel-performance.conf"

  local has_ssl="false"
  if [ "$ENABLE_HTTPS" == "true" ] && [ -n "$SSL_CERT_PATH" ] && [ -n "$SSL_KEY_PATH" ]; then
    has_ssl="true"
  fi
  local https_port_segment=""
  if [ "$has_ssl" == "true" ] && [ "$HTTPS_PORT" != "443" ]; then
    https_port_segment=":${HTTPS_PORT}"
  fi


  cat <<EOF | $SUDO tee "$config_path" >/dev/null
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  '' close;
}

upstream adpanel_backend {
  server ${upstream_host}:${upstream_port};
  keepalive 64;
}

server {
  listen ${HTTP_PORT};
  server_name ${server_name};
  server_tokens off;
  client_max_body_size 1100m;
  root ${static_root};

  if (\$request_method = TRACE) {
    return 444;
  }
  if (\$request_method = TRACK) {
    return 444;
  }
  if (\$request_method = OPTIONS) {
    return 204;
  }

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  keepalive_requests 1000;

EOF

  if [ "$has_ssl" == "true" ] && [ "$FORCE_HTTPS" == "true" ]; then
    cat <<EOF | $SUDO tee -a "$config_path" >/dev/null
  return 301 https://\$host${https_port_segment}\$request_uri;
}
EOF
  else
    cat <<EOF | $SUDO tee -a "$config_path" >/dev/null
  gzip on;
  gzip_vary on;
  gzip_min_length 256;
  gzip_comp_level 5;
  gzip_proxied any;
  gzip_types text/plain text/css application/javascript application/json application/xml application/rss+xml image/svg+xml application/vnd.ms-fontobject application/x-font-ttf font/opentype;

EOF
    if [ "$nginx_has_brotli" == "true" ]; then
      cat <<EOF | $SUDO tee -a "$config_path" >/dev/null
  brotli on;
  brotli_comp_level 5;
  brotli_min_length 256;
  brotli_types text/plain text/css application/javascript application/json application/xml application/rss+xml image/svg+xml application/vnd.ms-fontobject application/x-font-ttf font/opentype;

EOF
    fi
    cat <<EOF | $SUDO tee -a "$config_path" >/dev/null

  location = /_stealth/nginx-auth {
    internal;
    proxy_pass http://adpanel_backend/_stealth/nginx-auth;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
  }

  location @adpanel_stealth_404 {
    internal;
    default_type text/plain;
    add_header Cache-Control "no-store, private" always;
    return 404 "";
  }

  location ^~ /.well-known/acme-challenge/ {
    auth_request off;
    access_log off;
    try_files \$uri @adpanel_backend;
  }

  location = /favicon.ico {
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location ^~ /auth-assets/ {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location = /branding-media/login-watermark {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location = /branding-media/login-background {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location = /login.css {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    access_log off;
  }

  location = /images/adpanel-dark.webp {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    access_log off;
  }

  location = /images/ADPanel-christmas.png {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    access_log off;
  }

  location = /images/bgvid.webm {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    access_log off;
  }

  location /css/ {
    alias ${static_root}/css/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    etag on;
    access_log off;
    open_file_cache max=1000 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 1;
  }

  location /js/ {
    alias ${static_root}/js/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    etag on;
    access_log off;
    open_file_cache max=1000 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 1;
  }

  location /images/ {
    alias ${static_root}/images/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    etag on;
    access_log off;
    open_file_cache max=500 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 1;
  }

  location ~* \\.(?:woff2?|ttf|eot|otf)\$ {
    try_files \$uri =404;
    expires 365d;
    add_header Cache-Control "public, max-age=31536000, immutable";
    add_header Access-Control-Allow-Origin "*";
    access_log off;
  }

  location ~* ^/[^/]+\\.(?:css|js|mjs|png|jpe?g|gif|ico|svg|webp)\$ {
    try_files \$uri =404;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    etag on;
    access_log off;
  }

  location / {
    try_files \$uri @adpanel_backend;
  }

  location ~ ^/api/nodes/server/[^/]+/logs\$ {
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_buffering off;
    proxy_cache off;
    add_header X-Accel-Buffering no always;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;

    proxy_set_header Connection "";
  }

  location @adpanel_backend {
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    proxy_buffering on;
    proxy_buffer_size 16k;
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
  }
}
EOF
  fi

  if [ "$has_ssl" == "true" ]; then
    cat <<EOF | $SUDO tee "$ssl_config_path" >/dev/null
server {
  listen ${HTTPS_PORT} ssl http2;
  server_name ${server_name};
  server_tokens off;
  root ${static_root};

  if (\$request_method = TRACE) {
    return 444;
  }
  if (\$request_method = TRACK) {
    return 444;
  }
  if (\$request_method = OPTIONS) {
    return 204;
  }

  ssl_certificate ${SSL_CERT_PATH};
  ssl_certificate_key ${SSL_KEY_PATH};
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

  client_max_body_size 1100m;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  keepalive_requests 1000;

  gzip on;
  gzip_vary on;
  gzip_min_length 256;
  gzip_comp_level 5;
  gzip_proxied any;
  gzip_types text/plain text/css application/javascript application/json application/xml application/rss+xml image/svg+xml application/vnd.ms-fontobject application/x-font-ttf font/opentype;

EOF
    if [ "$nginx_has_brotli" == "true" ]; then
      cat <<EOF | $SUDO tee -a "$ssl_config_path" >/dev/null
  brotli on;
  brotli_comp_level 5;
  brotli_min_length 256;
  brotli_types text/plain text/css application/javascript application/json application/xml application/rss+xml image/svg+xml application/vnd.ms-fontobject application/x-font-ttf font/opentype;

EOF
    fi
    cat <<EOF | $SUDO tee -a "$ssl_config_path" >/dev/null

  location = /_stealth/nginx-auth {
    internal;
    proxy_pass http://adpanel_backend/_stealth/nginx-auth;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
  }

  location @adpanel_stealth_404 {
    internal;
    default_type text/plain;
    add_header Cache-Control "no-store, private" always;
    return 404 "";
  }

  location ^~ /.well-known/acme-challenge/ {
    auth_request off;
    access_log off;
    try_files \$uri @adpanel_backend;
  }

  location = /favicon.ico {
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location ^~ /auth-assets/ {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location = /branding-media/login-watermark {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location = /branding-media/login-background {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_set_header Connection "";
  }

  location = /login.css {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    access_log off;
  }

  location = /images/adpanel-dark.webp {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    access_log off;
  }

  location = /images/ADPanel-christmas.png {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    access_log off;
  }

  location = /images/bgvid.webm {
    auth_request /_stealth/nginx-auth;
    error_page 401 403 = @adpanel_stealth_404;
    try_files \$uri =404;
    add_header Cache-Control "no-store, private" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    access_log off;
  }

  location /css/ {
    alias ${static_root}/css/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    etag on;
    access_log off;
    open_file_cache max=1000 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 1;
  }

  location /js/ {
    alias ${static_root}/js/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    etag on;
    access_log off;
    open_file_cache max=1000 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 1;
  }

  location /images/ {
    alias ${static_root}/images/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    etag on;
    access_log off;
    open_file_cache max=500 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 1;
  }

  location ~* \\.(?:woff2?|ttf|eot|otf)\$ {
    try_files \$uri =404;
    expires 365d;
    add_header Cache-Control "public, max-age=31536000, immutable";
    add_header Access-Control-Allow-Origin "*";
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    access_log off;
  }

  location ~* ^/[^/]+\\.(?:css|js|mjs|png|jpe?g|gif|ico|svg|webp)\$ {
    try_files \$uri =404;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    etag on;
    access_log off;
  }

  location / {
    try_files \$uri @adpanel_backend;
  }

  location ~ ^/api/nodes/server/[^/]+/logs\$ {
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_buffering off;
    proxy_cache off;
    add_header X-Accel-Buffering no always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;

    proxy_set_header Connection "";
  }

  location @adpanel_backend {
    proxy_pass http://adpanel_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    proxy_buffering on;
    proxy_buffer_size 16k;
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
  }
}
EOF
  else
    $SUDO rm -f "$ssl_config_path" >/dev/null 2>&1 || true
  fi

  if [ "$layout" == "debian" ]; then
    $SUDO ln -sf "$config_path" /etc/nginx/sites-enabled/adpanel.conf
    if [ -f "$ssl_config_path" ]; then
      $SUDO ln -sf "$ssl_config_path" /etc/nginx/sites-enabled/adpanel-ssl.conf
    else
      $SUDO rm -f /etc/nginx/sites-enabled/adpanel-ssl.conf
    fi
  fi

  fix_nginx_static_permissions "$panel_root"

  apply_nginx_performance_profile

  if $SUDO nginx -t; then
    if [ "$layout" == "debian" ] && [ -f /etc/nginx/sites-enabled/default ]; then
      $SUDO rm -f /etc/nginx/sites-enabled/default
      if ! $SUDO nginx -t; then
        ui_warn "nginx failed after disabling the default site; restoring the default site."
        restore_path_from_backup "/etc/nginx/sites-enabled/default" "${backup_dir}/enabled-default"
        $SUDO nginx -t >/dev/null 2>&1 || true
      fi
    fi
    service_reload nginx
    rm -rf "$backup_dir" >/dev/null 2>&1 || true
    return 0
  fi

  ui_warn "Generated nginx configuration failed validation; restoring the previous nginx config."
  restore_path_from_backup "$config_path" "${backup_dir}/adpanel.conf"
  restore_path_from_backup "$ssl_config_path" "${backup_dir}/adpanel-ssl.conf"
  restore_path_from_backup "/etc/nginx/sites-enabled/adpanel.conf" "${backup_dir}/enabled-adpanel.conf"
  restore_path_from_backup "/etc/nginx/sites-enabled/adpanel-ssl.conf" "${backup_dir}/enabled-adpanel-ssl.conf"
  restore_path_from_backup "/etc/nginx/sites-enabled/default" "${backup_dir}/enabled-default"
  restore_path_from_backup "/etc/nginx/conf.d/adpanel-performance.conf" "${backup_dir}/adpanel-performance.conf"
  $SUDO nginx -t >/dev/null 2>&1 && service_reload nginx || true
  rm -rf "$backup_dir" >/dev/null 2>&1 || true
  return 1
}

apply_nginx_performance_profile() {
  local nginx_conf="/etc/nginx/nginx.conf"
  local perf_conf="/etc/nginx/conf.d/adpanel-performance.conf"
  local cache_dir="/var/cache/nginx/adpanel"
  local nginx_user=""

  if [ ! -f "$nginx_conf" ]; then
    ui_warn "nginx.conf not found; skipping nginx performance profile."
    return 0
  fi

  nginx_user="$(detect_nginx_user)"
  $SUDO mkdir -p "$cache_dir" >/dev/null 2>&1 || true
  if [ -n "$nginx_user" ] && id "$nginx_user" >/dev/null 2>&1; then
    $SUDO chown -R "$nginx_user":"$nginx_user" "$cache_dir" >/dev/null 2>&1 || true
  fi

  # Raise FD and connection capacity while keeping worker auto-scaling enabled.
  if ! grep -qE '^[[:space:]]*worker_rlimit_nofile[[:space:]]+' "$nginx_conf"; then
    $SUDO sed -i '/^worker_processes[[:space:]]\+auto;/a worker_rlimit_nofile 65535;' "$nginx_conf" || true
  fi

  $SUDO sed -i -E 's/^[[:space:]]*worker_connections[[:space:]]+[0-9]+;/    worker_connections 4096;/' "$nginx_conf" || true
  $SUDO sed -i 's/^[[:space:]]*#[[:space:]]*multi_accept[[:space:]]\+on;/    multi_accept on;/' "$nginx_conf" || true

  if ! grep -qE '^[[:space:]]*use[[:space:]]+epoll;' "$nginx_conf"; then
    $SUDO sed -i '/^[[:space:]]*multi_accept[[:space:]]\+on;/a\    use epoll;' "$nginx_conf" || true
  fi

  cat <<'EOF' | $SUDO tee "$perf_conf" >/dev/null
# ADPanel nginx performance profile (managed by initialize.sh)
# Kept intentionally directive-free because this file is included in the
# nginx http {} context, where many distro defaults already define
# keepalive/gzip/client timeout directives. Duplicating them breaks nginx -t
# on Rocky/Alma/CentOS and other RHEL-compatible layouts.
EOF
}

BCRYPT_CODE="
let bcrypt;
try { bcrypt = require('bcrypt'); } catch (e) {
  console.log('Using bcryptjs fallback');
  bcrypt = require('bcryptjs');
}
module.exports = bcrypt;
"

change_password() {
  ui_section "=== Change an user password ==="

  if ! ensure_node_prerequisites; then
    ui_error "Cannot continue without the required Node.js runtime and extensions."
    return 1
  fi

  read -p "$(ui_prompt "Enter user email: ")" EMAIL

  read -s -p "$(ui_prompt "Enter current password: ")" CURRENT
  echo ""

  while true; do
    read -s -p "$(ui_prompt "Enter new password: ")" NEW1
    echo ""
    read -s -p "$(ui_prompt "Confirm new password: ")" NEW2
    echo ""
    if [ "$NEW1" != "$NEW2" ]; then
      ui_error "Passwords do not match. Try again."
    else
      break
    fi
  done

  HASH=$(node -e "
    let bcrypt;
    try { bcrypt = require('bcrypt'); } catch (e) { bcrypt = require('bcryptjs'); }
    console.log(bcrypt.hashSync(process.argv[1] || '', 10));
  " "$NEW1")

  if [ -z "$CREATE_USER_SCRIPT" ]; then
    ui_error "create-user.js not found; cannot update password."
    exit 1
  fi

  if [ -n "$CURRENT" ]; then
    $SUDO node "$CREATE_USER_SCRIPT" --update-password --email "$EMAIL" --password-hash "$HASH" --current-password "$CURRENT"
  else
    $SUDO node "$CREATE_USER_SCRIPT" --update-password --email "$EMAIL" --password-hash "$HASH"
  fi
}

delete_user() {
  ui_section "=== Delete an user ==="

  if ! ensure_node_prerequisites; then
    ui_error "Cannot continue without the required Node.js runtime and extensions."
    return 1
  fi

  read -p "$(ui_prompt "Enter user email: ")" EMAIL
  ui_warn "This will permanently delete the user: ${EMAIL}"
  read -p "$(ui_prompt "Type YES to confirm: ")" CONFIRM
  if [ "$CONFIRM" != "YES" ]; then
    ui_warn "Cancelled."
    exit 0
  fi

  if [ -z "$CREATE_USER_SCRIPT" ]; then
    ui_error "create-user.js not found; cannot delete user."
    exit 1
  fi

  $SUDO node "$CREATE_USER_SCRIPT" --delete --email "$EMAIL"
}

initialize_panel() {
  ui_section "=== Panel Initialization ==="
  repair_openssh_cross_distro_config || true
  apply_adpanel_host_limits || true

  read -p "$(ui_prompt "Enter admin email: ")" EMAIL
  read -s -p "$(ui_prompt "Enter admin password: ")" PASSWORD
  echo ""

  if ! ensure_node_prerequisites; then
    ui_error "Cannot continue without the required system packages, Node.js runtime, and extensions."
    return 1
  fi

  SECRET=$(node - <<'EOF'
const speakeasy = require('speakeasy');
console.log(speakeasy.generateSecret({length: 20}).base32);
EOF
)

  ui_warn "Your 2FA secret (manual entry works too): $SECRET"

  ui_info "Scan this QR code in your Authenticator app:"
  node -e "
    const speakeasy = require('speakeasy');
    const qrcode = require('qrcode-terminal');
    const otpAuth = speakeasy.otpauthURL({
      secret: process.argv[1],
      label: process.argv[2],
      issuer: 'ADPanel',
      encoding: 'base32'
    });
    qrcode.generate(otpAuth, { small: true });
  " "$SECRET" "$EMAIL"

  HASH=$(node -e "
    let bcrypt;
    try { bcrypt = require('bcrypt'); } catch (e) { bcrypt = require('bcryptjs'); }
    console.log(bcrypt.hashSync(process.argv[1] || '', 10));
  " "$PASSWORD")

  ui_section "=== Network & HTTPS configuration ==="

  read -p "$(ui_prompt "Enter host to bind (default 0.0.0.0): ")" HOST
  HOST=${HOST:-0.0.0.0}

  read -p "$(ui_prompt "Do you want to use a domain name for the panel? (yes/no, default no): ")" DOMAIN_CHOICE
  DOMAIN_CHOICE="$(lower_trim "$DOMAIN_CHOICE")"
  PANEL_DOMAIN=""
  if [ "$DOMAIN_CHOICE" == "yes" ] || [ "$DOMAIN_CHOICE" == "y" ]; then
    read -p "$(ui_prompt "Enter domain (e.g. panel.example.com): ")" PANEL_DOMAIN
    PANEL_DOMAIN="$(trim_ws "$PANEL_DOMAIN")"
    if echo "$PANEL_DOMAIN" | tr '[:upper:]' '[:lower:]' | grep -q "adpanel"; then
      ui_warn "This hostname contains 'adpanel'. Public TLS certificates are logged in Certificate Transparency logs, so a neutral hostname is better for stealth."
    fi
  fi

  if [ -n "$PANEL_DOMAIN" ]; then
    NGINX_SERVER_NAME="$PANEL_DOMAIN"
    CSRF_ALLOWED_HOSTS="$PANEL_DOMAIN"
    PANEL_PUBLIC_HOST="$PANEL_DOMAIN"
  else
    ui_info "Detecting public IP..."
    inputs_ip="$(detect_default_panel_ip)"

    ui_warn "No domain selected. To prevent CSRF issues, we need the IP you will use to access the panel."
    read -p "$(ui_prompt "Enter panel IP (default ${inputs_ip}): ")" PANEL_IP_IN
    PANEL_IP_IN="$(trim_ws "$PANEL_IP_IN")"
    if [ -z "$PANEL_IP_IN" ]; then
      PANEL_IP_IN="$inputs_ip"
    fi

    NGINX_SERVER_NAME="$PANEL_IP_IN"
    CSRF_ALLOWED_HOSTS="$PANEL_IP_IN"
    PANEL_PUBLIC_HOST="$PANEL_IP_IN"
    ui_success "Configured for IP access: ${PANEL_IP_IN}"
  fi

  read -p "$(ui_prompt "Do you want to enable HTTPS? (yes/no, default yes): ")" HTTPS_CHOICE
  HTTPS_CHOICE="$(lower_trim "$HTTPS_CHOICE")"

  if [ -z "$HTTPS_CHOICE" ] || [ "$HTTPS_CHOICE" == "yes" ] || [ "$HTTPS_CHOICE" == "y" ]; then
    ENABLE_HTTPS=true

    read -p "$(ui_prompt "Enter HTTP port (default 80): ")" HTTP_PORT
    HTTP_PORT="$(normalize_port "$HTTP_PORT" 80)"

    read -p "$(ui_prompt "Enter HTTPS port (default 443): ")" HTTPS_PORT
    HTTPS_PORT="$(normalize_port "$HTTPS_PORT" 443)"

    read -p "$(ui_prompt "Force redirect HTTP to HTTPS? (yes/no, default yes): ")" FORCE_CHOICE
    FORCE_CHOICE="$(lower_trim "$FORCE_CHOICE")"
    if [ -z "$FORCE_CHOICE" ] || [ "$FORCE_CHOICE" == "yes" ] || [ "$FORCE_CHOICE" == "y" ]; then
      FORCE_HTTPS=true
    else
      FORCE_HTTPS=false
    fi

    SESSION_COOKIE_SECURE=true
    if [ "$HTTP_PORT" != "80" ]; then
      ui_warn "Note: Let's Encrypt validation typically needs port 80 reachable. HTTP_PORT=$HTTP_PORT may cause issues."
    fi

  else
    ENABLE_HTTPS=false
    FORCE_HTTPS=false
    SESSION_COOKIE_SECURE=false

    read -p "$(ui_prompt "Enter HTTP port (default 80): ")" HTTP_PORT
    HTTP_PORT="$(normalize_port "$HTTP_PORT" 80)"

    HTTPS_PORT=443
  fi

  NGINX_ENABLED=false
  APP_HOST="127.0.0.1"
  APP_PORT=3001
  if [ "$HTTP_PORT" == "$APP_PORT" ] || [ "$HTTPS_PORT" == "$APP_PORT" ]; then
    APP_PORT=3002
  fi

  SSL_KEY_PATH=
  SSL_CERT_PATH=

  ui_info "Generating strong SESSION_SECRET..."
  SESSION_SECRET=$(node - <<'EOF'
const crypto = require('crypto');
const min = 64;
const max = 99;
const length = Math.floor(Math.random() * (max - min + 1)) + min;
const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
let result = '';
const bytes = crypto.randomBytes(length);
for (let i = 0; i < length; i++) {
  result += chars[bytes[i] % chars.length];
}
console.log(result);
EOF
)

  ui_info "Generating DUMMY_HASH..."
  DUMMY_HASH=$(node - <<'EOF'
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
const length = 64;
let raw = '';
const bytes = crypto.randomBytes(length);
for (let i = 0; i < length; i++) {
  raw += chars[bytes[i] % chars.length];
}
const hash = bcrypt.hashSync(raw, 10);
console.log(hash);
EOF
)

  ui_section "=== Captcha configuration (optional) ==="
  read -p "$(ui_prompt "Enter SITE_KEY (leave blank to disable captcha): ")" SITE_KEY
  SITE_KEY="$(trim_ws "$SITE_KEY")"
  read -s -p "$(ui_prompt "Enter SECRET_KEY (leave blank to disable captcha): ")" SECRET_KEY
  echo ""
  SECRET_KEY="$(trim_ws "$SECRET_KEY")"

  setup_redis || true
  if ! setup_mysql; then
    ui_error "MySQL/MariaDB setup failed. The panel needs a working database for user storage."
    return 1
  fi

  # Enterprise security: lock down MariaDB and optionally harden firewall
  if is_mysql_installed; then
    secure_mariadb_binding || true
  fi
  FIREWALL_HARDEN="${ADPANEL_FIREWALL_HARDEN:-}"
  if [ -z "$FIREWALL_HARDEN" ]; then
    read -p "$(ui_prompt "Apply firewall hardening for SMB/MySQL? This may install or enable a firewall service (yes/no, default no): ")" FIREWALL_HARDEN
  fi
  FIREWALL_HARDEN="$(lower_trim "$FIREWALL_HARDEN")"
  if [ "$FIREWALL_HARDEN" == "yes" ] || [ "$FIREWALL_HARDEN" == "y" ]; then
    harden_firewall
  else
    ui_warn "Skipping automatic firewall hardening. You can configure firewall rules manually later."
  fi
  mask_service_versions
  ensure_stealth_config "$PANEL_ROOT"

  if install_nginx; then
    service_enable nginx
    service_start nginx
    if write_nginx_config; then
      NGINX_ENABLED=true
    else
      NGINX_ENABLED=false
      ui_warn "nginx installed but ADPanel nginx config could not be validated; panel will run directly."
    fi
  else
    ui_warn "nginx install failed; panel will run without reverse proxy."
  fi

  if [ "$ENABLE_HTTPS" == "true" ]; then
    if [ -z "$PANEL_DOMAIN" ]; then
      ui_warn "No domain provided; skipping Let's Encrypt certificate generation."
    else
      if install_certbot; then
        ensure_certbot_nginx_plugin >/dev/null 2>&1 || true
        ui_info "Requesting Let's Encrypt certificate for: ${PANEL_DOMAIN}"
        ui_info "Running certbot in non-interactive mode with admin email: ${EMAIL}"
        if [ "$NGINX_ENABLED" == "true" ]; then
          $SUDO certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring
        else
          $SUDO certbot certonly --standalone -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring
        fi

        if [ $? -eq 0 ]; then
          SSL_KEY_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
          SSL_CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"
          ui_success "Certificate obtained successfully!"
        else
          ui_error "certbot failed or was cancelled. SSL paths will be left empty."
          SSL_KEY_PATH=
          SSL_CERT_PATH=
        fi
      else
        ui_error "certbot could not be installed. SSL paths will be left empty."
        SSL_KEY_PATH=
        SSL_CERT_PATH=
      fi
    fi
  fi

  if [ "$ENABLE_HTTPS" == "true" ] && { [ -z "$SSL_CERT_PATH" ] || [ -z "$SSL_KEY_PATH" ]; }; then
    ui_warn "HTTPS enabled but SSL cert/key missing. Falling back to HTTP-only."
    ENABLE_HTTPS=false
    FORCE_HTTPS=false
    SESSION_COOKIE_SECURE=false
  fi

  if [ "$NGINX_ENABLED" == "true" ]; then
    if ! write_nginx_config; then
      NGINX_ENABLED=false
      ui_warn "Final nginx config validation failed; panel will run directly."
    fi
  fi

  if [ "$NGINX_ENABLED" != "true" ]; then
    if [ "$HTTP_PORT" -lt 1024 ] 2>/dev/null; then
      ui_warn "nginx is not enabled; using HTTP_PORT=3001 so the non-root panel service can bind safely."
      HTTP_PORT=3001
    fi
    if [ "$ENABLE_HTTPS" == "true" ] && [ "$HTTPS_PORT" -lt 1024 ] 2>/dev/null; then
      ui_warn "nginx is not enabled; using HTTPS_PORT=3443 so the non-root panel service can bind safely."
      HTTPS_PORT=3443
    fi
  fi

  local public_scheme="http"
  local public_port="$HTTP_PORT"
  if [ "$ENABLE_HTTPS" == "true" ]; then
    public_scheme="https"
    public_port="$HTTPS_PORT"
  fi
  PANEL_PUBLIC_URL="$(build_public_url "$public_scheme" "$PANEL_PUBLIC_HOST" "$public_port")"

  configure_panel_firewall "$NGINX_ENABLED" "$HOST" "$HTTP_PORT" "$ENABLE_HTTPS" "$HTTPS_PORT"

  cat <<EOF > .env
HOST=$HOST
CSRF_ALLOWED_HOSTS=$CSRF_ALLOWED_HOSTS
PANEL_PUBLIC_URL=$PANEL_PUBLIC_URL
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
ENABLE_HTTPS=$ENABLE_HTTPS
FORCE_HTTPS=$FORCE_HTTPS
SSL_KEY_PATH=$SSL_KEY_PATH
SSL_CERT_PATH=$SSL_CERT_PATH
SESSION_COOKIE_SECURE=$SESSION_COOKIE_SECURE
SESSION_STORE=$SESSION_STORE
NGINX_ENABLED=$NGINX_ENABLED
APP_HOST=$APP_HOST
APP_PORT=$APP_PORT
STEALTH_MODE=true
STEALTH_COOKIE_TTL_DAYS=30
STEALTH_RESPONSE_FLOOR_MS=90
STEALTH_ALLOW_HEALTHCHECK=false
SITE_KEY="$SITE_KEY"
SECRET_KEY="$SECRET_KEY"
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT
REDIS_USER=$REDIS_USER
REDIS_PASSWORD="$REDIS_PASSWORD"
REDIS_URL="$REDIS_URL"
MYSQL_HOST=$MYSQL_HOST
MYSQL_PORT=$MYSQL_PORT
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD="$MYSQL_PASSWORD"
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_URL="$MYSQL_URL"
LOGIN_SUSPICIOUS_ATTEMPTS=5
LOGIN_SUSPICIOUS_FAST_WINDOW_MS=20000
LOGIN_SUSPICIOUS_FAST_ATTEMPTS=3
LOGIN_SUSPICIOUS_WINDOW_MS=300000
SESSION_SECRET="$SESSION_SECRET"
DUMMY_HASH="$DUMMY_HASH"
BROTLI_QUALITY=4
SSH_TERM_PORT=9393
SSH_TERM_BIND=127.0.0.1:9393
SSH_TERM_INTERNAL_URL=http://127.0.0.1:9393
SSH_TERM_PUBLIC_URL=
SSH_TERM_WS_PUBLIC_URL=
EOF

  ui_success ".env file created with network and security settings."
  ensure_panel_env_permissions "$PANEL_ROOT"

  if bootstrap_db_and_create_admin "$EMAIL" "$HASH" "$SECRET"; then
    ui_success "Admin account created in database."
  else
    ui_warn "Panel setup completed, but admin account creation in database failed."
  fi
  ui_warn "Panel setup complete!"
  if [ "$NGINX_ENABLED" == "true" ]; then
    ui_kv "Panel URL:" "$PANEL_PUBLIC_URL"
  else
    ui_warn "nginx reverse proxy is disabled; use the direct panel URL below."
    ui_kv "Panel URL:" "$PANEL_PUBLIC_URL"
  fi

  if [ "$INIT_SYSTEM" != "unknown" ]; then
    ui_info "Configuring and starting service: adpanel-sshterm..."
    if ensure_go_runtime && setup_adpanel_sshterm_service; then
      case "$INIT_SYSTEM" in
        systemd) ui_kv "  SSH Terminal status:" "systemctl status adpanel-sshterm" ;;
        openrc) ui_kv "  SSH Terminal status:" "rc-service adpanel-sshterm status" ;;
        sysv) ui_kv "  SSH Terminal status:" "service adpanel-sshterm status" ;;
      esac
    else
      ui_warn "SSH terminal service setup skipped."
    fi
  else
    ui_warn "SSH terminal service setup skipped because init system is unsupported: ${INIT_SYSTEM}."
  fi

  ui_info "Configuring and starting service: adpanel..."
  if ! setup_adpanel_service; then
    ui_error "Failed to configure/start adpanel service. Exiting."
    return 1
  fi
  print_adpanel_service_commands
}

uninstall_adpanel() {
  local panel_root="$PANEL_ROOT"

  ui_section "Uninstall ADPanel"
  ui_warn "This will PERMANENTLY remove this ADPanel installation from the server."
  log_platform_summary

  # --- Step B: hard safety guard on the target directory --------------------
  # Refuse to operate on empty / root / well-known system directories, and
  # require the directory to actually look like an ADPanel install. This is the
  # main backstop against a catastrophic "rm -rf" if PANEL_ROOT resolved wrong.
  if [ -z "$panel_root" ] || [ "$panel_root" == "/" ]; then
    ui_error "Refusing to uninstall: panel root is empty or '/'."
    return 1
  fi
  local protected_dir
  for protected_dir in /root /home /usr /etc /var /var/www /bin /boot /opt /srv /lib /sbin; do
    if [ "$panel_root" == "$protected_dir" ]; then
      ui_error "Refusing to uninstall: panel root '${panel_root}' is a protected system directory."
      return 1
    fi
  done
  if [ ! -f "${panel_root}/index.js" ] || [ ! -f "${panel_root}/initialize.sh" ]; then
    ui_error "Refusing to uninstall: '${panel_root}' does not look like an ADPanel installation."
    ui_warn "Expected to find index.js and initialize.sh there. Aborting without changes."
    return 1
  fi

  # --- Step A: gather details before deleting anything ----------------------
  # Read DB credentials and the TLS cert path from .env while it still exists.
  MYSQL_URL=""; MYSQL_HOST=""; MYSQL_PORT=""
  MYSQL_USER=""; MYSQL_PASSWORD=""; MYSQL_DATABASE=""
  load_mysql_env >/dev/null 2>&1 || true

  local ssl_cert_path cert_name=""
  ssl_cert_path="$(read_env_file_value "${panel_root}/.env" "SSL_CERT_PATH" 2>/dev/null || true)"
  if [ -n "$ssl_cert_path" ] && [[ "$ssl_cert_path" == /etc/letsencrypt/live/* ]]; then
    cert_name="${ssl_cert_path#/etc/letsencrypt/live/}"
    cert_name="${cert_name%%/*}"
  fi

  ui_section "The following will be removed"
  ui_kv "  Panel directory:" "$panel_root"
  ui_kv "  Services:" "adpanel, adpanel-sshterm"
  ui_kv "  Binary:" "/usr/local/bin/adpanel-sshterm"
  ui_kv "  nginx vhosts:" "adpanel.conf, adpanel-ssl.conf, adpanel-performance.conf"
  ui_kv "  System drop-ins:" "99-adpanel-* (sysctl, limits, MySQL)"
  if [ -n "$cert_name" ]; then
    ui_kv "  TLS certificate:" "$cert_name (certbot)"
  fi
  if [ -n "$MYSQL_DATABASE" ] || [ -n "$MYSQL_USER" ]; then
    ui_kv "  Database (asked separately):" "${MYSQL_DATABASE:-?} / user '${MYSQL_USER:-?}'"
  fi
  ui_warn "Shared software (nginx, MySQL/MariaDB, Redis, Node.js, Go) will NOT be uninstalled."

  # --- Step C: main confirmation -------------------------------------------
  local confirm=""
  read -p "$(ui_prompt "Type the panel path or 'UNINSTALL' to confirm: ")" confirm
  confirm="$(trim_ws "$confirm")"
  if [ "$confirm" != "$panel_root" ] && [ "$confirm" != "UNINSTALL" ]; then
    ui_warn "Confirmation did not match. Aborting; nothing was changed."
    return 1
  fi

  # --- Step D: stop, disable and remove services ---------------------------
  local svc
  for svc in adpanel adpanel-sshterm; do
    ui_info "Stopping and removing service: ${svc}..."
    service_stop "$svc"
    case "$INIT_SYSTEM" in
      systemd)
        $SUDO systemctl disable "$svc" >/dev/null 2>&1 || true
        $SUDO rm -f "/etc/systemd/system/${svc}.service" >/dev/null 2>&1 || true
        ;;
      openrc)
        $SUDO rc-update del "$svc" default >/dev/null 2>&1 || true
        $SUDO rm -f "/etc/init.d/${svc}" >/dev/null 2>&1 || true
        ;;
      sysv)
        if cmd_exists update-rc.d; then
          $SUDO update-rc.d -f "$svc" remove >/dev/null 2>&1 || true
        elif cmd_exists chkconfig; then
          $SUDO chkconfig "$svc" off >/dev/null 2>&1 || true
        fi
        $SUDO rm -f "/etc/init.d/${svc}" >/dev/null 2>&1 || true
        ;;
    esac
  done
  if [ "$INIT_SYSTEM" == "systemd" ]; then
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  # --- Step E: remove the sshterm binary -----------------------------------
  $SUDO rm -f /usr/local/bin/adpanel-sshterm >/dev/null 2>&1 || true

  # --- Step F: remove nginx artifacts, then validate and reload ------------
  ui_info "Removing ADPanel nginx configuration..."
  $SUDO rm -f \
    /etc/nginx/sites-available/adpanel.conf \
    /etc/nginx/sites-available/adpanel-ssl.conf \
    /etc/nginx/sites-enabled/adpanel.conf \
    /etc/nginx/sites-enabled/adpanel-ssl.conf \
    /etc/nginx/conf.d/adpanel.conf \
    /etc/nginx/conf.d/adpanel-ssl.conf \
    /etc/nginx/conf.d/adpanel-performance.conf \
    >/dev/null 2>&1 || true
  if cmd_exists nginx; then
    if $SUDO nginx -t >/dev/null 2>&1; then
      service_reload nginx
    else
      ui_warn "nginx config validation failed after removing ADPanel vhosts; not reloading nginx."
      ui_warn "Check 'nginx -t' manually."
    fi
  fi

  # --- Step G: remove ADPanel-named system / MySQL drop-ins ----------------
  # Only adpanel-named files are removed; shared MySQL config is never touched.
  ui_info "Removing ADPanel system tuning and MySQL drop-ins..."
  $SUDO rm -f /etc/sysctl.d/99-adpanel-host-limits.conf >/dev/null 2>&1 || true
  $SUDO sysctl --system >/dev/null 2>&1 || true
  $SUDO rm -f /etc/security/limits.d/99-adpanel-nofile.conf >/dev/null 2>&1 || true
  local mysql_confdir
  for mysql_confdir in /etc/mysql/mariadb.conf.d /etc/mysql/mysql.conf.d /etc/my.cnf.d; do
    $SUDO rm -f \
      "${mysql_confdir}/99-adpanel-security.cnf" \
      "${mysql_confdir}/99-adpanel-version-mask.cnf" \
      >/dev/null 2>&1 || true
  done

  # --- Step H: delete the panel's TLS certificate --------------------------
  if [ -n "$cert_name" ] && cmd_exists certbot; then
    ui_info "Deleting TLS certificate '${cert_name}'..."
    $SUDO certbot delete --cert-name "$cert_name" --non-interactive >/dev/null 2>&1 \
      || ui_warn "Could not delete certbot certificate '${cert_name}'; remove it manually if needed."
  fi

  # --- Step I: drop the database (separate, explicit confirmation) ---------
  if [ -n "$MYSQL_DATABASE" ] && [ -n "$MYSQL_USER" ]; then
    local esc_user esc_pass esc_db
    esc_user="$(mysql_sql_escape "$MYSQL_USER")"
    esc_db="$(printf "%s" "$MYSQL_DATABASE" | sed "s/\`//g")"

    if ! printf "%s" "$esc_user" | grep -qE '^[A-Za-z0-9_@.-]+$'; then
      ui_warn "MySQL username contains unsupported characters; skipping database removal."
    elif ! printf "%s" "$esc_db" | grep -qE '^[A-Za-z0-9_]+$'; then
      ui_warn "MySQL database name contains unsupported characters; skipping database removal."
    else
      local drop_db=""
      ui_warn "About to DROP database '${esc_db}' and user '${esc_user}'. This destroys all panel data."
      read -p "$(ui_prompt "Drop the ADPanel database and user? (yes/no, default no): ")" drop_db
      drop_db="$(lower_trim "$drop_db")"
      if [ "$drop_db" == "yes" ] || [ "$drop_db" == "y" ]; then
        local drop_sql
        drop_sql=$(cat <<EOF
DROP DATABASE IF EXISTS \`$esc_db\`;
DROP USER IF EXISTS '$esc_user'@'localhost';
DROP USER IF EXISTS '$esc_user'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
)
        if mysql_exec_as_root "$drop_sql"; then
          ui_success "Database '${esc_db}' and user '${esc_user}' removed."
        else
          ui_warn "Could not drop the database via root socket auth; remove it manually if needed."
        fi
      else
        ui_info "Keeping the ADPanel database and user."
      fi
    fi
  fi

  # --- Step J: remove the panel directory ----------------------------------
  # The script cd'd into PANEL_ROOT at startup; move out before deleting it.
  ui_info "Removing panel directory: ${panel_root}..."
  cd / 2>/dev/null || true
  $SUDO rm -rf "$panel_root" >/dev/null 2>&1 || true
  if [ -e "$panel_root" ]; then
    ui_warn "Some files under '${panel_root}' could not be removed; check permissions."
  fi

  # --- Step K: final report -------------------------------------------------
  ui_section "ADPanel uninstalled"
  ui_success "ADPanel has been removed from this server."
  ui_info "Left untouched on purpose:"
  ui_kv "  Packages:" "nginx, MySQL/MariaDB, Redis, Node.js, Go (still installed)"
  ui_kv "  Shared config:" "MySQL/Redis server settings and any non-ADPanel data"
  ui_kv "  System user:" "'adpanel' if it existed (the installer never created it)"
  ui_kv "  Cert archive:" "/etc/letsencrypt (other domains untouched)"
  return 0
}

repair_sshterm_service() {
  ui_section "Repair SSH terminal service"
  log_platform_summary

  if [ ! -f "${PANEL_ROOT}/.env" ]; then
    ui_warn ".env was not found. The SSH terminal needs SESSION_SECRET from an initialized panel."
    ui_warn "Run option 1 first if this is a new ADPanel install."
  fi

  if ensure_go_runtime && setup_adpanel_sshterm_service; then
    case "$INIT_SYSTEM" in
      systemd)
        ui_success "SSH terminal service repaired."
        ui_kv "  Status:" "systemctl status adpanel-sshterm"
        ;;
      openrc)
        ui_success "SSH terminal service repaired."
        ui_kv "  Status:" "rc-service adpanel-sshterm status"
        ;;
      sysv)
        ui_success "SSH terminal service repaired."
        ui_kv "  Status:" "service adpanel-sshterm status"
        ;;
    esac
    return 0
  fi

  ui_error "Failed to repair SSH terminal service."
  return 1
}

load_mysql_env() {
  if [ ! -f "${PANEL_ROOT}/.env" ]; then
    ui_error ".env not found. Run 'Initialize Panel' first."
    return 1
  fi

  local values
  values=$(node - <<'EOF'
const fs = require("fs");
const path = require("path");
const envPath = path.join(process.cwd(), ".env");
if (!fs.existsSync(envPath)) process.exit(2);
let parsed = {};
try {
  const dotenv = require("dotenv");
  parsed = dotenv.parse(fs.readFileSync(envPath, "utf8"));
} catch (err) {
  console.error(err && err.message ? err.message : String(err));
  process.exit(3);
}
const keys = ["MYSQL_URL", "MYSQL_HOST", "MYSQL_PORT", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DATABASE"];
for (const key of keys) {
  const raw = parsed[key];
  process.stdout.write((raw == null ? "" : String(raw)).replace(/\r?\n/g, ""));
  process.stdout.write("\n");
}
EOF
)
  if [ $? -ne 0 ]; then
    ui_error "Failed to read MySQL settings from .env."
    return 1
  fi

  local env_values=()
  mapfile -t env_values <<< "$values"
  MYSQL_URL="${env_values[0]:-}"
  MYSQL_HOST="${env_values[1]:-}"
  MYSQL_PORT="${env_values[2]:-}"
  MYSQL_USER="${env_values[3]:-}"
  MYSQL_PASSWORD="${env_values[4]:-}"
  MYSQL_DATABASE="${env_values[5]:-}"

  if [ -z "$MYSQL_URL" ] && { [ -z "$MYSQL_HOST" ] || [ -z "$MYSQL_DATABASE" ]; }; then
    ui_error "MySQL is not configured in .env. Set MYSQL_URL or MYSQL_HOST/MYSQL_DATABASE."
    return 1
  fi

  return 0
}

mysql_configured_user_can_connect() {
  local cli
  cli="$(mysql_detect_cli)"
  [ -n "$MYSQL_DATABASE" ] && [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_HOST" ] && [ -n "$MYSQL_PORT" ] || return 1
  cmd_exists "$cli" || return 1

  MYSQL_PWD="$MYSQL_PASSWORD" "$cli" \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$MYSQL_USER" \
    -e "SELECT 1;" "$MYSQL_DATABASE" >/dev/null 2>&1
}

repair_mysql_credentials_from_env() {
  ui_section "Repair MySQL credentials"
  if ! load_mysql_env; then
    return 1
  fi

  if mysql_configured_user_can_connect; then
    ui_success "MySQL credentials from .env are already valid."
    return 0
  fi

  if [ -z "$MYSQL_DATABASE" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
    ui_error "MYSQL_DATABASE, MYSQL_USER or MYSQL_PASSWORD is missing from .env."
    return 1
  fi

  local esc_user esc_pass esc_db
  esc_user="$(mysql_sql_escape "$MYSQL_USER")"
  esc_pass="$(mysql_sql_escape "$MYSQL_PASSWORD")"
  esc_db="$(printf "%s" "$MYSQL_DATABASE" | sed "s/\`//g")"

  if ! printf "%s" "$esc_user" | grep -qE '^[A-Za-z0-9_@.-]+$'; then
    ui_error "MySQL username contains unsupported characters; cannot repair automatically."
    return 1
  fi
  if ! printf "%s" "$esc_db" | grep -qE '^[A-Za-z0-9_]+$'; then
    ui_error "MySQL database name contains unsupported characters; cannot repair automatically."
    return 1
  fi

  local sql
  sql=$(cat <<EOF
CREATE DATABASE IF NOT EXISTS \`$esc_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '$esc_user'@'localhost' IDENTIFIED BY '$esc_pass';
CREATE USER IF NOT EXISTS '$esc_user'@'127.0.0.1' IDENTIFIED BY '$esc_pass';
ALTER USER '$esc_user'@'localhost' IDENTIFIED BY '$esc_pass';
ALTER USER '$esc_user'@'127.0.0.1' IDENTIFIED BY '$esc_pass';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES
ON \`$esc_db\`.*
TO '$esc_user'@'localhost';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES
ON \`$esc_db\`.*
TO '$esc_user'@'127.0.0.1';

FLUSH PRIVILEGES;
EOF
)

  if ! mysql_exec_as_root "$sql"; then
    ui_error "Could not repair MySQL credentials via root socket auth."
    ui_warn "Run this as root on the panel host, or re-run option 1 and enter the MySQL root password if prompted."
    return 1
  fi

  if mysql_configured_user_can_connect; then
    ui_success "MySQL credentials repaired from .env."
    return 0
  fi

  ui_error "MySQL user was updated, but .env credentials still cannot connect."
  return 1
}

create_user() {
  ui_section "=== Create New User ==="

  if ! ensure_node_prerequisites; then
    ui_error "Cannot continue without the required Node.js runtime and extensions."
    return 1
  fi

  read -p "$(ui_prompt "Enter user email: ")" EMAIL
  EMAIL="$(trim_ws "$EMAIL")"
  if [ -z "$EMAIL" ]; then
    ui_error "Email cannot be empty."
    return 1
  fi
  while true; do
    read -s -p "$(ui_prompt "Enter user password: ")" PASS1
    echo ""
    read -s -p "$(ui_prompt "Confirm user password: ")" PASS2
    echo ""
    if [ "$PASS1" != "$PASS2" ]; then
      ui_error "Passwords do not match. Try again."
    else
      break
    fi
  done

  read -p "$(ui_prompt "Should this user be an admin? (y/n): ")" ISADMIN

  SECRET=$(node - <<'EOF'
const speakeasy = require('speakeasy');
console.log(speakeasy.generateSecret({length: 20}).base32);
EOF
)

  ui_warn "Your 2FA secret (manual entry works too): $SECRET"

  ui_info "Scan this QR code in your Authenticator app:"
  node -e "
    const speakeasy = require('speakeasy');
    const qrcode = require('qrcode-terminal');
    const otpAuth = speakeasy.otpauthURL({
      secret: process.argv[1],
      label: process.argv[2],
      issuer: 'ADPanel',
      encoding: 'base32'
    });
    qrcode.generate(otpAuth, { small: true });
  " "$SECRET" "$EMAIL"

  local create_script="$CREATE_USER_SCRIPT"
  if [ -z "$create_script" ]; then
    ui_error "create-user.js not found; cannot create user."
    return 1
  fi

  if ! load_mysql_env; then
    return 1
  fi

  local admin_flag=""
  local avatar_url=""
  if lower_trim "$ISADMIN" | grep -qE '^y'; then
    admin_flag="--admin"
    avatar_url="$(pick_default_avatar_url admin)"
  else
    avatar_url="$(pick_default_avatar_url user)"
  fi
  ui_info "Assigned avatar: ${avatar_url}"

  local env_cmd=(env)
  [ -n "$MYSQL_URL" ] && env_cmd+=("MYSQL_URL=$MYSQL_URL")
  [ -n "$MYSQL_HOST" ] && env_cmd+=("MYSQL_HOST=$MYSQL_HOST")
  [ -n "$MYSQL_PORT" ] && env_cmd+=("MYSQL_PORT=$MYSQL_PORT")
  [ -n "$MYSQL_USER" ] && env_cmd+=("MYSQL_USER=$MYSQL_USER")
  env_cmd+=("MYSQL_PASSWORD=$MYSQL_PASSWORD")
  [ -n "$MYSQL_DATABASE" ] && env_cmd+=("MYSQL_DATABASE=$MYSQL_DATABASE")

  local cmd=("${env_cmd[@]}" node "$create_script" --email "$EMAIL" --password "$PASS1" --secret "$SECRET")
  if [ -n "$admin_flag" ]; then
    cmd+=("$admin_flag")
  fi
  if [ -n "$avatar_url" ]; then
    cmd+=("--avatar-url" "$avatar_url")
  fi
  if [ -n "$SUDO" ]; then
    cmd=("$SUDO" "${cmd[@]}")
  fi

  "${cmd[@]}"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    ui_error "Failed to create user in MySQL."
    return "$rc"
  fi

  ui_success "User created successfully in MySQL."
}

if [ "$CHOICE" == "1" ]; then
  initialize_panel
elif [ "$CHOICE" == "2" ]; then
  change_password
elif [ "$CHOICE" == "3" ]; then
  delete_user
elif [ "$CHOICE" == "4" ]; then
  create_user
elif [ "$CHOICE" == "5" ]; then
  uninstall_adpanel
elif [ "$CHOICE" == "6" ]; then
  repair_sshterm_service
elif [ "$CHOICE" == "7" ]; then
  repair_mysql_credentials_from_env
else
  ui_error "Invalid choice. Exiting."
  exit 1
fi
