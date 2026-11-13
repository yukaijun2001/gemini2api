#!/usr/bin/env bash
# gemini2api 一键部署。默认监听宿主 10002，容器内仍是 5918。
# Cookie、账号和运行参数在 Web 控制台配置，不用手改 .env。
#
#   ./deploy.sh            构建并启动
#   ./deploy.sh down       停止并删除容器
#   ./deploy.sh restart    重启
#   ./deploy.sh logs       跟随日志
#   ./deploy.sh status     查看状态
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

HOST_PORT="${HOST_PORT:-10002}"
CONTAINER_PORT=5918
IMAGE_NAME="${IMAGE_NAME:-gemini2api:local}"
ACTION="${1:-up}"

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
  local key
  key="$(read_api_key)"
  printf '\n已启动，直接打开控制台即可使用。\n'
  printf '  控制台  http://127.0.0.1:%s\n' "$HOST_PORT"
  printf '  API Key  %s\n' "$key"
  printf '  账号和 Cookie 在控制台「账号管理」里添加，不用改 .env。\n\n'
}

cmd_up() {
  check_docker
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
  check_docker
  ensure_env
  ensure_runtime_dirs
  write_overlay
  compose restart
  if wait_healthy; then
    print_ready
  else
    die "重启后健康检查未通过，请执行 ./deploy.sh logs"
  fi
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
