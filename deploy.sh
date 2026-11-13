#!/usr/bin/env bash
# gemini2api 一键部署。默认监听宿主 10003，容器内仍是 5918。
# Cookie、账号和运行参数在 Web 控制台配置，不用手改 .env。
#
#   ./deploy.sh            拉取 GitHub 最新代码，然后构建并启动
#   SKIP_PULL=1 ./deploy.sh  不拉代码，直接用当前目录部署
#   ./deploy.sh down       停止并删除容器
#   ./deploy.sh restart    拉取最新代码并重新部署
#   ./deploy.sh logs       跟随日志
#   ./deploy.sh status     查看状态
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

HOST_PORT="${HOST_PORT:-10003}"
CONTAINER_PORT=5918
IMAGE_NAME="${IMAGE_NAME:-gemini2api:local}"
ACTION="${1:-up}"
SKIP_PULL="${SKIP_PULL:-0}"
# 可选：手动指定对外地址。不设则自动探测内网 IP 和公网 IP。
PUBLIC_HOST="${PUBLIC_HOST:-}"

OVERLAY=""
DOCKERIGNORE_BACKUP=""

die() {
  printf 'deploy.sh: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令 $1"
}

compose() {
  docker compose -f "$ROOT/docker-compose.yml" -f "$OVERLAY" "$@"
}

cleanup() {
  if [[ -n "$DOCKERIGNORE_BACKUP" && -f "$DOCKERIGNORE_BACKUP" ]]; then
    mv "$DOCKERIGNORE_BACKUP" "$ROOT/.dockerignore"
    DOCKERIGNORE_BACKUP=""
  fi
  if [[ -n "$OVERLAY" && -f "$OVERLAY" ]]; then
    rm -f "$OVERLAY"
  fi
}
trap cleanup EXIT



is_private_ip() {
  local ip="$1"
  [[ "$ip" == 10.* || "$ip" == 192.168.* || "$ip" == 127.* || "$ip" == 169.254.* ]] && return 0
  [[ "$ip" == 172.1[6-9].* || "$ip" == 172.2[0-9].* || "$ip" == 172.3[0-1].* ]] && return 0
  return 1
}

detect_lan_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  fi
  if [[ -z "$ip" ]] && command -v ipconfig >/dev/null 2>&1; then
    local iface
    for iface in en0 en1 eth0; do
      ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
      [[ -n "$ip" ]] && break
    done
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s\n' "$ip"
}

detect_public_ip() {
  local ip="" url
  if command -v curl >/dev/null 2>&1; then
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      ip="$(curl -4 -fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$ip"
        return
      fi
    done
  fi
  printf '\n'
}

sync_repo() {
  if [[ "$SKIP_PULL" == "1" ]]; then
    printf '已跳过拉取代码（SKIP_PULL=1）。\n'
    return
  fi

  need_cmd git
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 git 仓库，无法拉取 GitHub 代码"

  local branch remote_ref before after script_backup keep_script old_sum new_sum
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  [[ -n "$branch" ]] || die "当前是游离 HEAD，请先切回分支再部署"
  remote_ref="origin/${branch}"

  printf '正在拉取 GitHub %s ...\n' "$remote_ref"
  GIT_TERMINAL_PROMPT=0 git fetch --prune origin "$branch"
  git rev-parse --verify --quiet "${remote_ref}^{commit}" >/dev/null || die "远程没有 ${remote_ref}"

  before="$(git rev-parse --short HEAD)"
  script_backup="$(mktemp)"
  cp -p "$ROOT/deploy.sh" "$script_backup"
  old_sum="$(cksum "$script_backup" | awk '{print $1" "$2}')"
  keep_script=0
  if [[ -n "$(git status --porcelain -- deploy.sh)" ]]; then
    keep_script=1
  fi

  git reset --hard "$remote_ref"
  git clean -fd -e /data -e /api -e /.env -e '/.env.*' -e /deploy.sh

  if [[ "$keep_script" -eq 1 ]]; then
    cp -p "$script_backup" "$ROOT/deploy.sh"
    chmod +x "$ROOT/deploy.sh"
    printf '保留了本地尚未提交的 deploy.sh。\n'
  fi
  rm -f "$script_backup"

  after="$(git rev-parse --short HEAD)"
  if [[ "$before" == "$after" ]]; then
    printf '代码已是最新：%s\n' "$after"
  else
    printf '代码已更新：%s -> %s\n' "$before" "$after"
  fi

  new_sum="$(cksum "$ROOT/deploy.sh" | awk '{print $1" "$2}')"
  if [[ "$old_sum" != "$new_sum" && -z "${DEPLOY_REEXECED:-}" ]]; then
    printf 'deploy.sh 已随仓库更新，改用新脚本继续部署。\n'
    export DEPLOY_REEXECED=1
    exec "$ROOT/deploy.sh" "$ACTION"
  fi
}

check_docker() {
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose）"
  docker info >/dev/null 2>&1 || die "Docker 未运行，请先启动 Docker"
}

generate_api_key() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'sk-%s\n' "$(openssl rand -hex 16)"
    return
  fi
  need_cmd python3
  python3 -c 'import secrets; print("sk-" + secrets.token_hex(16))'
}

ensure_env() {
  local key=""
  if [[ ! -f .env ]]; then
    key="$(generate_api_key)"
    cat > .env <<EOF
# 由 deploy.sh 自动生成。账号、Cookie 和运行参数请在 Web 控制台修改，不要手改本文件。
API_KEY=${key}
ACCOUNTS_FILE=data/accounts.json
EOF
    chmod 600 .env
    return
  fi

  if grep -Eq '^API_KEY=.+' .env; then
    return
  fi

  key="$(generate_api_key)"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" '
    BEGIN { done = 0 }
    /^API_KEY=/ && !done { print "API_KEY=" key; done = 1; next }
    { print }
    END { if (!done) print "API_KEY=" key }
  ' .env > "$tmp"
  mv "$tmp" .env
  chmod 600 .env
}

read_api_key() {
  local line
  line="$(grep -E '^API_KEY=.+' .env | tail -n 1 || true)"
  printf '%s\n' "${line#API_KEY=}"
}

ensure_runtime_dirs() {
  mkdir -p data api
  if [[ ! -f data/accounts.json ]]; then
    printf '%s\n' '{ "accounts": [] }' > data/accounts.json
  fi
}

write_overlay() {
  OVERLAY="$(mktemp)"
  cat > "$OVERLAY" <<EOF
services:
  gemini2api:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${IMAGE_NAME}
    ports: !override
      - "${HOST_PORT}:${CONTAINER_PORT}"
EOF
}

include_api_assets() {
  DOCKERIGNORE_BACKUP="$(mktemp)"
  cp .dockerignore "$DOCKERIGNORE_BACKUP"
  grep -v '^api$' .dockerignore > .dockerignore.tmp
  mv .dockerignore.tmp .dockerignore
}

wait_healthy() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

print_ready() {
  local key lan public
  key="$(read_api_key)"
  printf '\n已启动。账号和 Cookie 在控制台「账号管理」里添加，不用改 .env。\n'
  printf '  API Key  %s\n' "$key"
  if [[ -n "$PUBLIC_HOST" ]]; then
    printf '  控制台  http://%s:%s\n\n' "$PUBLIC_HOST" "$HOST_PORT"
    return
  fi
  lan="$(detect_lan_ip)"
  public="$(detect_public_ip)"
  printf '  本机    http://127.0.0.1:%s\n' "$HOST_PORT"
  if [[ -n "$lan" && "$lan" != "127.0.0.1" ]]; then
    if is_private_ip "$lan"; then
      printf '  内网    http://%s:%s\n' "$lan" "$HOST_PORT"
    else
      printf '  公网    http://%s:%s\n' "$lan" "$HOST_PORT"
    fi
  fi
  if [[ -n "$public" && "$public" != "$lan" && "$public" != "127.0.0.1" ]]; then
    printf '  公网    http://%s:%s\n' "$public" "$HOST_PORT"
  fi
  if [[ -z "$lan" && -z "$public" ]]; then
    printf '  未能探测到服务器 IP，请用服务器实际地址访问端口 %s。\n' "$HOST_PORT"
  fi
  printf '  外网打不开时，放行防火墙或安全组的 %s 端口。\n\n' "$HOST_PORT"
}

cmd_up() {
  check_docker
  sync_repo
  ensure_env
  ensure_runtime_dirs
  write_overlay
  include_api_assets
  compose up -d --build --remove-orphans
  if wait_healthy; then
    print_ready
  else
    printf '\n容器已启动，但健康检查还没通过。最近日志：\n' >&2
    compose logs --tail 80 >&2 || true
    die "请执行 ./deploy.sh logs 查看原因"
  fi
}

cmd_down() {
  check_docker
  write_overlay
  compose down
}

cmd_restart() {
  cmd_up
}

cmd_logs() {
  check_docker
  write_overlay
  compose logs -f --tail 200
}

cmd_status() {
  check_docker
  write_overlay
  compose ps
  curl -fsS "http://127.0.0.1:${HOST_PORT}/health" && printf '\n' || true
}

case "$ACTION" in
  up|start) cmd_up ;;
  down|stop) cmd_down ;;
  restart) cmd_restart ;;
  logs) cmd_logs ;;
  status|ps) cmd_status ;;
  -h|--help|help)
    sed -n '2,9p' "$0"
    ;;
  *)
    die "未知命令: $ACTION（可用 up / down / restart / logs / status）"
    ;;
esac
