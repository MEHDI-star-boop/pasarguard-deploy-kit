#!/bin/bash
# ------------------------------------------------------------------------
# PasarGuard Reseller Bot - Customer Deploy Kit Installer
#
# این فایل هیچ سورس پایتونی نداره - فقط یک ایمیج داکر آماده (پرایوت) رو از
# رجیستری فروشنده pull می‌کنه و اجراش می‌کنه. سورس اصلی فقط پیش فروشنده‌ست.
#
# ⚠️ فروشنده: قبل از توزیع، فقط کافیه vendor-config.env.example رو کپی کنی
# به vendor-config.env و پرش کنی - دیگه نیازی به ویرایش خودِ این فایل نیست.
#
# One-line install (run as root on a fresh Ubuntu server):
#
#   curl -fsSL <DEPLOY_KIT_BASE_URL>/install.sh | bash
#
# After first install, a global command is available from anywhere:
#   pasarguardbot update | rollback | backup | status | logs | doctor | remove
#
# Unattended install:
#   bash install.sh --unattended --token 123:ABC... --admin 123456789 --license XXXX-XXXX-XXXX-XXXX
# ------------------------------------------------------------------------
set -uo pipefail

INSTALL_DIR="/opt/pasarguard_reseller_bot"
INSTALL_LOG="/tmp/pasarguard_bot_install.log"
CLI_LINK="/usr/local/bin/pasarguardbot"
LAST_GOOD_IMAGE_FILE=".last_good_image_id"

# 📍 پوشه‌ی واقعی که این اسکریپت ازش اجرا میشه رو پیدا می‌کنیم. چون
# `pasarguardbot` یه symlink به همین install.sh (هرجا که واقعاً نصب شده) هست،
# با readlink مسیر واقعی فایل و در نتیجه پوشه‌ی نصب رو درمیاریم - مستقل از
# اینکه نصب توی /opt باشه یا هرجای دیگه (مثلاً /root/...). اگه اسکریپت مستقیم
# (نه از طریق symlink) اجرا بشه، همون مسیر خودش استفاده میشه.
_self="${BASH_SOURCE[0]}"
_resolved="$(readlink -f "$_self" 2>/dev/null || echo "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_resolved")" && pwd)"
unset _self _resolved

# ⚠️ این مقادیر رو دیگه اینجا (توی خودِ اسکریپت) ویرایش نکن - سه راه امن‌تر
# برای پرکردنشون هست (به ترتیب اولویت، پایین‌تر override می‌کنه):
#   ۱. متغیر محیطی موقع اجرا (برای نصب یک‌خطی امن - نگاه کن به پایین)
#   ۲. فایل "vendor-config.env" کنار همین install.sh (از روی
#      vendor-config.env.example کپی کن) - برای zip دستی که به مشتری می‌دی
#   ۳. همین مقدارهای پیش‌فرض پایین (خالی) - اگه هیچ‌کدوم از بالا نباشه
#
# 🔒 نصب یک‌خطی امن (بدون آپلود دستی فایل، بدون افشای توکن توی اسکریپت
# عمومی): وقتی install.sh رو از DEPLOY_KIT_BASE_URL عمومی هاست می‌کنی، خودِ
# این فایل نباید توکن واقعی توش باشه - به‌جاش موقع اجرا از طریق متغیر محیطی
# (که فقط تو خط فرمان لحظه‌ای خودت می‌بینیش، نه توی اسکریپت ذخیره‌شده) بده:
#
#   curl -fsSL <DEPLOY_KIT_BASE_URL>/install.sh | \
#     REGISTRY_TOKEN_DEFAULT="ghp_xxx" REGISTRY_USER_DEFAULT="you" \
#     BOT_IMAGE_DEFAULT="ghcr.io/you/image:latest" \
#     LICENSE_SERVER_URL_DEFAULT="https://license.yourdomain.com" \
#     sudo -E bash -s -- --unattended --token <BOT_TOKEN> --admin <ADMIN_ID> --license <LICENSE_KEY>
#
# (sudo -E لازمه چون sudo به‌طور پیش‌فرض متغیرهای محیطی رو پاک می‌کنه؛ -E
# نگهشون می‌داره تا به پروسه‌ی bash داخل pipe برسن.)
: "${DEPLOY_KIT_BASE_URL:=}"
: "${BOT_IMAGE_DEFAULT:=}"
: "${REGISTRY_URL_DEFAULT:=ghcr.io}"
: "${REGISTRY_USER_DEFAULT:=}"
: "${REGISTRY_TOKEN_DEFAULT:=}"
: "${LICENSE_SERVER_URL_DEFAULT:=}"

# اگه vendor-config.env کنار همین اسکریپت (یا توی INSTALL_DIR) باشه، مقادیر
# بالا (چه پیش‌فرض چه از متغیر محیطی) رو override می‌کنه.
for _cfg in "./vendor-config.env" "$INSTALL_DIR/vendor-config.env"; do
    if [ -f "$_cfg" ]; then
        # shellcheck disable=SC1090
        source "$_cfg"
        break
    fi
done
unset _cfg

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
GRAY='\033[0;37m'
BLUE='\033[1;34m'
NC='\033[0m'

UNATTENDED=0
ARG_TOKEN=""
ARG_ADMIN=""
ARG_DOMAIN=""
ARG_LICENSE=""

# ── UI helpers ──────────────────────────────────────────────────────────
_fmt_secs() {
    local s=$1
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"; else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}

banner() {
    echo -e "${BLUE}╭──────────────────────────────────────────────────╮${NC}"
    printf  "${BLUE}│${NC} ${CYAN}%-50s${NC} ${BLUE}│${NC}\n" "  PasarGuard Reseller Bot - Setup"
    echo -e "${BLUE}╰──────────────────────────────────────────────────╯${NC}"
}

step_ok()   { echo -e " ${GREEN}✔${NC} $1"; }
step_fail() { echo -e " ${RED}✘${NC} $1"; }
step_warn() { echo -e " ${YELLOW}⚠${NC} $1"; }
step_info() { echo -e " ${CYAN}ℹ${NC} $1"; }

run_step() {
    local msg="$1"
    local cmd="$2"
    : > "$INSTALL_LOG"
    local start
    start=$(date +%s)
    bash -c "$cmd" >> "$INSTALL_LOG" 2>&1 &
    local pid=$!
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local n=${#frames[@]}
    local i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        local el=$(( $(date +%s) - start ))
        printf "\r\033[K \033[1;33m%s\033[0m %s  \033[0;37m(%s)\033[0m" "${frames[$i]}" "$msg" "$(_fmt_secs "$el")"
        i=$(( (i + 1) % n ))
        sleep 0.2
    done
    wait "$pid"
    local rc=$?
    local el=$(( $(date +%s) - start ))
    tput cnorm 2>/dev/null
    if [ "$rc" -eq 0 ]; then
        printf "\r\033[K ${GREEN}✔${NC} %s ${GRAY}(%s)${NC}\n" "$msg" "$(_fmt_secs "$el")"
    else
        printf "\r\033[K ${RED}✘${NC} %s ${GRAY}(%s)${NC}\n" "$msg" "$(_fmt_secs "$el")"
        echo -e "${RED}──────────────── Error details ────────────────${NC}"
        tail -n 25 "$INSTALL_LOG"
        echo -e "${RED}────────────────────────────────────────────────${NC}"
    fi
    return "$rc"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Please run this script as root (sudo).${NC}"
        exit 1
    fi
}

# ── Phase 1: server checks ───────────────────────────────────────────────
check_server() {
    banner
    echo "Checking server..."
    echo ""

    if [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release; then
        step_ok "Ubuntu detected ($(. /etc/os-release && echo "$VERSION_ID"))"
    else
        step_warn "This doesn't look like Ubuntu - continuing anyway, but things may differ."
    fi

    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$ram_mb" -ge 1024 ]; then
        step_ok "RAM check (${ram_mb} MB)"
    else
        step_warn "Low RAM (${ram_mb} MB) - 1GB+ is recommended."
    fi

    local disk_gb
    disk_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
    if [ "$disk_gb" -ge 5 ]; then
        step_ok "Disk check (${disk_gb}GB free)"
    else
        step_warn "Low disk space (${disk_gb}GB free) - 5GB+ is recommended."
    fi

    if command -v docker >/dev/null 2>&1; then
        step_ok "Docker check ($(docker --version | cut -d, -f1))"
    else
        step_info "Docker not found yet - will be installed."
    fi

    local busy_ports=""
    for p in 5432 6379; do
        if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$p "; then
            busy_ports="$busy_ports $p"
        fi
    done
    if [ -z "$busy_ports" ]; then
        step_ok "Port check (5432, 6379 free)"
    else
        step_warn "Port(s) already in use:$busy_ports - Postgres/Redis run in host network mode and need these free."
    fi
    echo ""
}

harden_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        if ! run_step "Installing ufw" "apt-get update -y && apt-get install -y ufw"; then
            step_warn "ufw not available - skipping firewall hardening (Redis/Postgres still bound to 127.0.0.1 only)."
            return
        fi
    fi
    ufw deny 5432/tcp >/dev/null 2>&1 || true
    ufw deny 6379/tcp >/dev/null 2>&1 || true
    step_ok "Firewall: blocked external access to ports 5432/6379"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        run_step "Installing Docker" "curl -fsSL https://get.docker.com | sh" || exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}Docker Compose v2 not found. Please update Docker and try again.${NC}"
        exit 1
    fi
    if [ ! -f /etc/docker/daemon.json ]; then
        mkdir -p /etc/docker
        echo '{ "dns": ["8.8.8.8", "1.1.1.1"] }' > /etc/docker/daemon.json
        systemctl restart docker 2>/dev/null || true
    fi
}

# جایگزین ensure_repo قدیمی (که git clone می‌کرد) - این‌جا هیچ سورسی نیست،
# فقط ۲-۳ فایل غیرحساس (docker-compose.yml + این install.sh) لازمه که یا از
# قبل کنار هم باشن (کیت دستی/zip داده شده به مشتری) یا از DEPLOY_KIT_BASE_URL دانلود بشن.
ensure_deploy_dir() {
    # حالت ۱: از پوشه‌ای اجرا شده که خودش docker-compose.yml داره (نصب دستی،
    # یا اجرای مستقیم install.sh از داخل پوشه‌ی کیت). همین‌جا بمون.
    if [ -f "docker-compose.yml" ] && [ -f "install.sh" ]; then
        return
    fi
    # حالت ۲ (مهم برای `pasarguardbot update` از هرجای دیگه): برو به همون
    # پوشه‌ای که این اسکریپت واقعاً توش نصب شده (از روی symlink پیدا شد، بالای
    # فایل). این باعث میشه دستور از هرجای سیستم که زده بشه، روی نصب واقعی کار
    # کنه - مستقل از اینکه /opt باشه یا /root/... یا هرجای دیگه.
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        cd "$SCRIPT_DIR" || exit 1
        return
    fi
    # حالت ۳: نصب اولیه‌ی تازه - از مسیر پیش‌فرض استفاده کن.
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1

    if [ -f "docker-compose.yml" ] && [ -f "install.sh" ]; then
        return
    fi

    if [ -z "$DEPLOY_KIT_BASE_URL" ]; then
        echo -e "${RED}docker-compose.yml not found in $(pwd) and DEPLOY_KIT_BASE_URL isn't set.${NC}"
        echo -e "${RED}Copy the full deploy kit here manually (docker-compose.yml + install.sh), then re-run.${NC}"
        exit 1
    fi

    run_step "Downloading deploy files" \
        "curl -fsSL '${DEPLOY_KIT_BASE_URL}/docker-compose.yml' -o docker-compose.yml && \
         curl -fsSL '${DEPLOY_KIT_BASE_URL}/install.sh' -o install.sh && \
         chmod +x install.sh" || exit 1
}

docker_login_registry() {
    if [ -z "$REGISTRY_TOKEN_DEFAULT" ] || [ -z "$REGISTRY_USER_DEFAULT" ]; then
        return  # اگه فروشنده پرش نکرده (مثلاً ایمیج پابلیکه)، سایلنت رد میشه
    fi
    echo "$REGISTRY_TOKEN_DEFAULT" | docker login "$REGISTRY_URL_DEFAULT" -u "$REGISTRY_USER_DEFAULT" --password-stdin >/dev/null 2>&1
}

# فقط pull - هیچ fallback ساخت محلی نداریم چون سورس/Dockerfile این‌جا نیست.
# پوشه‌ی backups روی هاست، اگه از قبل وجود نداشته باشه، توسط خودِ Docker با
# مالکیت root ساخته میشه؛ ولی داخل کانتینر، ربات با یوزر غیر-روت (botuser,
# uid 1000 - نگاه کن به Dockerfile) اجرا میشه و اجازه‌ی نوشتن توی یه پوشه‌ی
# متعلق به root رو نداره (خطای "Permission denied" موقع بکاپ خودکار/دستی).
# برای همین قبل از هر compose up، این پوشه رو خودمون از قبل با مالکیت درست می‌سازیم.
ensure_backups_dir_permissions() {
    mkdir -p backups
    chown -R 1000:1000 backups 2>/dev/null || true
}

get_images() {
    docker_login_registry
    run_step "Pulling bot image" "docker compose pull"
}

install_cli_symlink() {
    local target
    target="$(pwd)/install.sh"
    if [ ! -f "$CLI_LINK" ] || [ "$(readlink -f "$CLI_LINK" 2>/dev/null)" != "$target" ]; then
        ln -sf "$target" "$CLI_LINK"
        chmod +x "$target"
        step_ok "Installed 'pasarguardbot' command (try: pasarguardbot status)"
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --unattended) UNATTENDED=1; shift ;;
            --token) ARG_TOKEN="${2:-}"; shift 2 ;;
            --admin) ARG_ADMIN="${2:-}"; shift 2 ;;
            --domain) ARG_DOMAIN="${2:-}"; shift 2 ;;
            --license) ARG_LICENSE="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -n "$ARG_TOKEN" ] && [ -n "$ARG_ADMIN" ]; then
        UNATTENDED=1
    fi
}

ensure_redis_password() {
    if [ ! -f .env ]; then
        return
    fi
    if grep -q '^REDIS_PASSWORD=' .env && [ -n "$(grep '^REDIS_PASSWORD=' .env | cut -d= -f2-)" ]; then
        return
    fi
    local redis_password
    redis_password="$(openssl rand -hex 24)"
    sed -i '/^REDIS_PASSWORD=/d' .env
    sed -i "s#^REDIS_URL=.*#REDIS_URL=redis://:${redis_password}@127.0.0.1:6379/0#" .env
    echo "REDIS_PASSWORD=${redis_password}" >> .env
    step_ok "Migrated: generated a Redis password for this existing install (was previously unauthenticated)"
}

# چک می‌کنه مقادیر ضروری فروشنده (از vendor-config.env یا هاردکد بالای همین
# فایل) واقعاً پر شدن - اگه نه، یه پیام واضح میده و متوقف میشه، به‌جای اینکه
# بعداً وسط pull/لایسنس با یه خطای گنگ (مثل docker login failed) گیر کنه.
require_vendor_config() {
    local missing=()
    [ -z "$BOT_IMAGE_DEFAULT" ] && missing+=("BOT_IMAGE")
    [ -z "$REGISTRY_USER_DEFAULT" ] && missing+=("REGISTRY_USER")
    [ -z "$REGISTRY_TOKEN_DEFAULT" ] && missing+=("REGISTRY_TOKEN")
    [ -z "$LICENSE_SERVER_URL_DEFAULT" ] && missing+=("LICENSE_SERVER_URL")

    if [ ${#missing[@]} -eq 0 ]; then
        return
    fi

    echo -e "${RED}Vendor configuration is incomplete - these values are still empty: ${missing[*]}${NC}"
    echo ""
    if [ -f "./vendor-config.env" ] || [ -f "$INSTALL_DIR/vendor-config.env" ]; then
        echo "vendor-config.env was found but one of the values above is empty - open it and fill it in."
    else
        echo "vendor-config.env was not found. Do the following:"
        echo "  1. cp vendor-config.env.example vendor-config.env"
        echo "  2. nano vendor-config.env   # fill in the required values"
        echo "  3. re-run this command"
    fi
    exit 1
}


do_install() {
    check_server
    require_docker
    harden_firewall
    ensure_deploy_dir
    require_vendor_config

    if [ -f .env ]; then
        step_warn ".env already exists - skipping first-time setup."
        ensure_redis_password
    else
        echo "First-time setup."
        echo ""

        local bot_token="$ARG_TOKEN"
        local admin_id="$ARG_ADMIN"
        local license_key="$ARG_LICENSE"

        if [ "$UNATTENDED" -eq 1 ]; then
            if [ -z "$bot_token" ] || [ -z "$admin_id" ] || [ -z "$license_key" ]; then
                echo -e "${RED}--unattended requires --token, --admin, and --license.${NC}"
                exit 1
            fi
        else
            while [ -z "$bot_token" ]; do
                read -rp "Bot Token: " bot_token < /dev/tty
            done
            while ! [[ "$admin_id" =~ ^[0-9]+$ ]]; do
                read -rp "Admin Telegram ID (numbers only): " admin_id < /dev/tty
            done
            while [ -z "$license_key" ]; do
                read -rp "License Key (from the seller): " license_key < /dev/tty
            done
        fi
        echo ""

        if [ -n "$LICENSE_SERVER_URL_DEFAULT" ]; then
            if curl -fsS --max-time 8 "${LICENSE_SERVER_URL_DEFAULT}/health" >/dev/null 2>&1; then
                step_ok "License server reachable."
            else
                step_warn "License server not reachable right now - the bot will keep retrying after install."
            fi
        fi
        echo ""

        local secret_key postgres_password redis_password
        secret_key="$(openssl rand -base64 32 | tr '+/' '-_')"
        postgres_password="$(openssl rand -hex 24)"
        redis_password="$(openssl rand -hex 24)"

        cat > .env << EOF
# Generated automatically by install.sh - do not commit this file to git.

BOT_IMAGE=${BOT_IMAGE_DEFAULT}

BOT_TOKEN=${bot_token}
ADMIN_IDS=${admin_id}
LICENSE_KEY=${license_key}
LICENSE_SERVER_URL=${LICENSE_SERVER_URL_DEFAULT}
SECRET_KEY=${secret_key}
DOMAIN=${ARG_DOMAIN}

POSTGRES_USER=bot
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=pasarguard_bot
DATABASE_URL=postgresql+asyncpg://bot:${postgres_password}@127.0.0.1:5432/pasarguard_bot
DB_POOL_SIZE=10
DB_POOL_MAX_OVERFLOW=20

REDIS_PASSWORD=${redis_password}
REDIS_URL=redis://:${redis_password}@127.0.0.1:6379/0

CARD_NUMBER=0000-0000-0000-0000
CARD_HOLDER="Card Holder Name"
SUPPORT_CONTACT=@your_support_username
PRICE_PER_GB=3000
PRICE_PER_DAY=1000
CURRENCY_LABEL=تومان
FREE_TRIAL_GB=1
FREE_TRIAL_DAYS=1
MIN_WALLET_TOPUP=10000
PANEL_RESELLER_ROLE_ID=3

BOT_RELEASE_VERSION=1.0.0
INFO_CHANNEL_USERNAME=@xMenderBot

BACKUP_RETENTION_DAYS=7
EOF
        chmod 600 .env
    fi

    echo ""
    ensure_backups_dir_permissions
    get_images || exit 1
    run_step "Running migrations & starting services" "docker compose up -d" || exit 1
    docker compose images -q bot > "$LAST_GOOD_IMAGE_FILE" 2>/dev/null || true

    install_cli_symlink
    setup_ssl
    run_health_checks
    show_summary
}

setup_ssl() {
    if [ -n "$ARG_DOMAIN" ]; then
        step_info "Domain '$ARG_DOMAIN' saved, but SSL/Nginx isn't set up yet."
    fi
}

run_health_checks() {
    echo ""
    echo "Running final checks..."
    load_env

    if docker compose exec -T db pg_isready -U "${POSTGRES_USER:-bot}" -h 127.0.0.1 >/dev/null 2>&1; then
        step_ok "Database OK"
    else
        step_fail "Database not responding"
    fi

    if docker compose exec -T redis redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD:-}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
        step_ok "Redis OK"
    else
        step_fail "Redis not responding"
    fi

    if [ -n "${BOT_TOKEN:-}" ] && curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null | grep -q '"ok":true'; then
        step_ok "Telegram connected"
    else
        step_fail "Could not reach Telegram with this bot token"
    fi

    local panel_rows
    panel_rows=$(docker compose exec -T db psql -U "${POSTGRES_USER:-bot}" -d "${POSTGRES_DB:-pasarguard_bot}" -tAc "SELECT count(*) FROM panel_config;" 2>/dev/null | tr -d '[:space:]')
    if [ "$panel_rows" ] && [ "$panel_rows" != "0" ]; then
        step_ok "Panel configured (use '🧪 Test connection' in the bot to verify it's reachable)"
    else
        step_warn "Panel not configured yet - do this from Telegram: Admin -> Settings -> Panel Management -> Add Panel"
    fi

    echo ""
    if docker compose logs bot --tail 20 2>/dev/null | grep -qi "لایسنس این ربات نامعتبره\|License.*invalid"; then
        step_fail "License check failed - see: pasarguardbot logs"
    fi
    echo ""
}

do_doctor() {
    ensure_deploy_dir
    run_health_checks
}

load_env() {
    if [ -f .env ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                ''|\#*) continue ;;
            esac
            export "$key=$value" 2>/dev/null || true
        done < .env
    fi
}

show_summary() {
    echo ""
    echo -e "${GREEN}╭──────────────────────────────────────────────────╮${NC}"
    printf  "${GREEN}│${NC} %-50s ${GREEN}│${NC}\n" "  Installation complete"
    echo -e "${GREEN}╰──────────────────────────────────────────────────╯${NC}"
    docker compose ps
    echo ""
    echo "Next step - configure the panel from inside Telegram:"
    echo -e "  ${CYAN}Admin -> Settings -> Panel Management -> Add Panel${NC}"
    echo ""
    echo "Useful commands (from anywhere now):"
    echo "  pasarguardbot status     # check service status"
    echo "  pasarguardbot logs       # follow bot logs"
    echo "  pasarguardbot update     # update to the latest version"
    echo "  pasarguardbot backup     # take a manual backup"
    echo "  pasarguardbot doctor     # re-run the health checks"
    echo ""
}

# ── Update / Rollback / Backup ────────────────────────────────────────────
do_backup() {
    ensure_deploy_dir
    load_env
    mkdir -p backups
    local out_file="backups/manual_$(date +%Y%m%d_%H%M%S).sql.gz"
    run_step "Backing up database" \
        "docker compose exec -T db pg_dump -U '${POSTGRES_USER:-bot}' -d '${POSTGRES_DB:-pasarguard_bot}' --clean --if-exists | gzip > '$out_file'"
    step_info "Saved to $out_file"
}

do_update() {
    banner
    require_docker
    harden_firewall
    ensure_deploy_dir
    require_vendor_config
    ensure_redis_password
    ensure_backups_dir_permissions

    do_backup

    # نسخه‌ی فعلی ایمیج رو قبل از آپدیت ذخیره می‌کنیم - برای rollback احتمالی
    docker compose images -q bot > "$LAST_GOOD_IMAGE_FILE" 2>/dev/null || true

    if [ -n "$DEPLOY_KIT_BASE_URL" ]; then
        run_step "Refreshing deploy files" \
            "curl -fsSL '${DEPLOY_KIT_BASE_URL}/docker-compose.yml' -o docker-compose.yml.new && mv docker-compose.yml.new docker-compose.yml" || true
    fi

    get_images || exit 1
    run_step "Restarting services" "docker compose up -d" || exit 1

    install_cli_symlink
    run_health_checks
    echo -e "${GREEN}Update complete.${NC} (run 'pasarguardbot rollback' if something looks wrong)"
}

do_rollback() {
    banner
    ensure_deploy_dir
    if [ ! -f "$LAST_GOOD_IMAGE_FILE" ] || [ ! -s "$LAST_GOOD_IMAGE_FILE" ]; then
        echo -e "${RED}No previous image recorded - nothing to roll back to.${NC}"
        exit 1
    fi
    local old_image_id
    old_image_id="$(cat "$LAST_GOOD_IMAGE_FILE")"

    if ! docker image inspect "$old_image_id" >/dev/null 2>&1; then
        echo -e "${RED}Previous image ($old_image_id) is no longer available locally${NC}"
        echo -e "${RED}(maybe 'docker system prune' ran since then) - can't roll back automatically.${NC}"
        exit 1
    fi

    load_env
    echo -e "${YELLOW}Rolling back image to the version before the last update...${NC}"
    echo -e "${YELLOW}Note: this only reverts the code, not the database. If the update${NC}"
    echo -e "${YELLOW}included a migration, you may need to restore a backup manually${NC}"
    echo -e "${YELLOW}(see: pasarguardbot restore <file>).${NC}"

    run_step "Re-tagging previous image" "docker tag '$old_image_id' '${BOT_IMAGE:-$BOT_IMAGE_DEFAULT}'" || exit 1
    run_step "Restarting services" "docker compose up -d" || exit 1
    run_health_checks
    echo -e "${GREEN}Rollback complete.${NC}"
}

do_restore() {
    ensure_deploy_dir
    local file="${1:-}"
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo "Usage: pasarguardbot restore <path-to-backup.sql.gz>"
        exit 1
    fi
    load_env
    echo -e "${YELLOW}This will overwrite the current database with $file.${NC}"
    read -rp "Type 'yes' to continue: " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
    docker compose stop bot worker
    # قبل از restore، اسکیمای فعلی رو کامل پاک می‌کنیم (نه فقط پیپ کردن مستقیم
    # بکاپ روش) - چون سرور جدید معمولاً از قبل migration خورده (جدول‌ها ساخته
    # شدن)، و بکاپ‌های قدیمی‌تر (قبل از افزودن --clean --if-exists به دستور
    # بکاپ) شامل DROP TABLE نیستن؛ بدون این پاک‌سازی، CREATE TABLE توی بکاپ با
    # خطای "relation already exists" شکست می‌خورد. این‌جوری، هم بکاپ‌های قدیمی
    # هم جدید، روی یه دیتابیس خالی یا از قبل migration‌خورده، یکسان کار می‌کنن.
    docker compose exec -T db psql -U "${POSTGRES_USER:-bot}" -d "${POSTGRES_DB:-pasarguard_bot}" \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
    gunzip -c "$file" | docker compose exec -T db psql -U "${POSTGRES_USER:-bot}" -d "${POSTGRES_DB:-pasarguard_bot}"
    docker compose start bot worker
    echo -e "${GREEN}Restore complete.${NC}"
}

do_remove() {
    ensure_deploy_dir
    echo -e "${YELLOW}This stops and removes the bot's containers.${NC}"
    read -rp "Also delete the database volume? This deletes ALL data. [y/N]: " CONFIRM < /dev/tty
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        run_step "Removing containers and volumes" "docker compose down -v"
    else
        run_step "Removing containers" "docker compose down"
    fi
}

do_migrate() {
    ensure_deploy_dir
    read -rp "Path to old SQLite bot_database.db file: " SQLITE_PATH < /dev/tty
    docker compose run --rm bot python migrate_sqlite_to_postgres.py "$SQLITE_PATH"
}

do_status() {
    ensure_deploy_dir
    docker compose ps
}

do_logs() {
    ensure_deploy_dir
    docker compose logs -f bot
}

show_help() {
    cat << 'EOF'
Usage: install.sh <command> [options]   (or: pasarguardbot <command>)

Commands:
  install               Install and start everything (first-time setup)
  update                Backup, pull latest image, restart
  rollback               Revert to the image before the last update
  backup                 Take a manual database backup now
  restore <file>         Restore the database from a backup file
  remove                 Stop and remove containers
  migrate                Migrate data from an old SQLite install
  status                 Show container status
  logs                   Follow the bot's logs
  doctor                 Run health checks (DB/Redis/Telegram/Panel/License)
  menu                   Show the interactive menu (default, no argument)

Unattended install:
  install.sh --unattended --token <BOT_TOKEN> --admin <TELEGRAM_ID> --license <LICENSE_KEY> [--domain <domain>]
EOF
}

main_menu() {
    banner
    echo "1) Install"
    echo "2) Update"
    echo "3) Rollback"
    echo "4) Backup now"
    echo "5) Remove"
    echo "6) Migrate (old SQLite -> PostgreSQL)"
    echo "7) Status"
    echo "8) Logs"
    echo "9) Doctor (health checks)"
    echo "10) Help"
    echo "11) Exit"
    echo ""
    read -rp "Select an option [1-11]: " CHOICE < /dev/tty
    case "$CHOICE" in
        1) do_install ;;
        2) do_update ;;
        3) do_rollback ;;
        4) do_backup ;;
        5) do_remove ;;
        6) do_migrate ;;
        7) do_status ;;
        8) do_logs ;;
        9) do_doctor ;;
        10) show_help ;;
        11) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
}

require_root
parse_args "$@"

CMD="menu"
for a in "$@"; do
    case "$a" in
        install|update|rollback|backup|restore|remove|migrate|status|logs|doctor|help|menu) CMD="$a" ;;
    esac
done

case "$CMD" in
    install) do_install ;;
    update) do_update ;;
    rollback) do_rollback ;;
    backup) do_backup ;;
    restore) do_restore "${2:-}" ;;
    remove) do_remove ;;
    migrate) do_migrate ;;
    status) do_status ;;
    logs) do_logs ;;
    doctor) do_doctor ;;
    help) show_help ;;
    menu|*)
        if [ "$UNATTENDED" -eq 1 ]; then
            do_install
        else
            main_menu
        fi
        ;;
esac
