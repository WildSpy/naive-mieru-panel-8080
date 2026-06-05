#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/opt/panel-naive-mieru"
INDEX_JS="${PANEL_DIR}/server/index.js"
TEMPLATE_JS="${PANEL_DIR}/server/caddyTemplate.js"
PANEL_CONFIG="/etc/rixxx-panel/config.json"
CADDY_FILE="/etc/caddy-naive/Caddyfile"
CADDY_BIN="/usr/local/bin/caddy-naive"
DB_PATH="/var/lib/rixxx-panel/db.sqlite"

PANEL_PUBLIC_PORT="8080"
PANEL_INTERNAL_HOST="127.0.0.1"
PANEL_INTERNAL_PORT="3000"

log() {
  echo -e "\033[0;32m[INFO]\033[0m $*"
}

warn() {
  echo -e "\033[1;33m[WARN]\033[0m $*"
}

err() {
  echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запусти от root: sudo bash fix-panel-8080.sh"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backup: ${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

check_files() {
  [[ -d "$PANEL_DIR" ]] || { err "Не найден каталог панели: $PANEL_DIR"; exit 1; }
  [[ -f "$INDEX_JS" ]] || { err "Не найден файл: $INDEX_JS"; exit 1; }
  [[ -f "$TEMPLATE_JS" ]] || { err "Не найден файл: $TEMPLATE_JS"; exit 1; }
  [[ -f "$PANEL_CONFIG" ]] || { err "Не найден файл: $PANEL_CONFIG"; exit 1; }
  [[ -x "$CADDY_BIN" ]] || { err "Не найден исполняемый Caddy: $CADDY_BIN"; exit 1; }
}

patch_caddy_template() {
  log "Патчим caddyTemplate.js: добавляем/исправляем reverse proxy панели на :${PANEL_PUBLIC_PORT}"

  backup_file "$TEMPLATE_JS"

  TEMPLATE_JS="$TEMPLATE_JS" \
  PANEL_PUBLIC_PORT="$PANEL_PUBLIC_PORT" \
  PANEL_INTERNAL_HOST="$PANEL_INTERNAL_HOST" \
  PANEL_INTERNAL_PORT="$PANEL_INTERNAL_PORT" \
  python3 - <<'PY'
from pathlib import Path
import os

template_js = os.environ["TEMPLATE_JS"]
public_port = os.environ["PANEL_PUBLIC_PORT"]
internal_host = os.environ["PANEL_INTERNAL_HOST"]
internal_port = os.environ["PANEL_INTERNAL_PORT"]

p = Path(template_js)
s = p.read_text()

# Нормализуем старый вариант, если он где-то был.
s = s.replace(f"http://:{public_port}", f":{public_port}")

panel_block = f"""
# Public web panel reverse proxy
:{public_port} {{
  reverse_proxy {internal_host}:{internal_port} {{
    header_up Host {{host}}
    header_up X-Real-IP {{remote_host}}
    header_up X-Forwarded-For {{remote_host}}
    header_up X-Forwarded-Proto http

    header_down -Content-Security-Policy
    header_down -Strict-Transport-Security
    header_down -Cross-Origin-Opener-Policy
    header_down -Cross-Origin-Embedder-Policy
    header_down -Cross-Origin-Resource-Policy
  }}
}}
"""

# Удаляем старый блок панели, если он уже есть в шаблоне.
marker = "# Public web panel reverse proxy"
idx = s.find(marker)
if idx != -1:
    # Блок панели должен быть в конце template literal перед `;.
    end_marker = "\n`;"
    end_idx = s.find(end_marker, idx)
    if end_idx == -1:
        raise SystemExit("Не удалось найти конец template literal после блока панели")
    s = s[:idx].rstrip() + s[end_idx:]

# Вставляем блок панели прямо перед закрытием template literal.
needle = "\n`;"
idx = s.rfind(needle)
if idx == -1:
    raise SystemExit("Не найден конец шаблона вида newline + backtick + semicolon")

s = s[:idx].rstrip() + "\n\n" + panel_block.rstrip() + s[idx:]

p.write_text(s)
print("OK: caddyTemplate.js patched")
PY

  log "Проверка генерации шаблона"
  cd "$PANEL_DIR"

  node - <<'NODE'
const fs = require('fs');
const tpl = require('./server/caddyTemplate.js');
const cfg = JSON.parse(fs.readFileSync('/etc/rixxx-panel/config.json', 'utf8'));

const out = tpl.render({
  adminEmail: cfg.adminEmail,
  domain: cfg.domain,
  naivePort: cfg.naivePort,
  fakeSiteDir: cfg.fakeSiteDir || '/var/www/fake-site',
  probeSecret: cfg.probeSecret || '',
  probeMode: cfg.probeMode || 'bare',
  logFile: '/var/log/caddy-naive/access.log',
  upstream: ''
}, [{ username: 'template_check', password: 'template_pass_123' }]);

if (!out.includes('# Public web panel reverse proxy')) {
  console.error('Template check failed: panel block is missing');
  process.exit(1);
}

if (!out.includes(':8080 {')) {
  console.error('Template check failed: :8080 block is missing');
  process.exit(1);
}

const lines = out.split('\n');
const panelLine = lines.findIndex(l => l.includes('# Public web panel reverse proxy'));

if (panelLine < 0) {
  console.error('Template check failed: panel marker not found');
  process.exit(1);
}

const before = lines.slice(Math.max(0, panelLine - 5), panelLine).join('\n');

if (!before.includes('}')) {
  console.error('Template check failed: panel block may be inside another block');
  process.exit(1);
}

console.log('OK: template renders panel block');
NODE
}

patch_reload_caddy() {
  log "Патчим server/index.js: reload Caddy с fallback на restart"

  backup_file "$INDEX_JS"

  python3 - <<PY
from pathlib import Path

p = Path("${INDEX_JS}")
s = p.read_text()

if "reload failed, falling back to restart" in s and "systemctl reload caddy-naive" in s:
    print("OK: reload fallback patch already exists")
    raise SystemExit(0)

old = """    try { execSync('systemctl reset-failed caddy-naive 2>/dev/null || true', { timeout: 5000 }); } catch {}
    execSync('systemctl restart caddy-naive', { timeout: 20000 });"""

new = """    try { execSync('systemctl reset-failed caddy-naive 2>/dev/null || true', { timeout: 5000 }); } catch {}

    try {
      execSync('systemctl reload caddy-naive', { timeout: 20000 });
    } catch (reloadError) {
      console.warn('[CADDY] reload failed, falling back to restart:', reloadError.message);
      execSync('systemctl restart caddy-naive', { timeout: 20000 });
    }"""

if old not in s:
    raise SystemExit("Не найден ожидаемый фрагмент с systemctl restart caddy-naive. Проверь вручную: sed -n '445,465p' ${INDEX_JS}")

s = s.replace(old, new, 1)
p.write_text(s)
print("OK: index.js patched")
PY
}

regenerate_caddyfile() {
  log "Перегенерируем текущий /etc/caddy-naive/Caddyfile из исправленного шаблона"

  backup_file "$CADDY_FILE"

  cd "$PANEL_DIR"

  node - <<'NODE' > /tmp/Caddyfile.rixxx-panel-8080
const fs = require('fs');
const Database = require('better-sqlite3');
const tpl = require('./server/caddyTemplate.js');

const cfg = JSON.parse(fs.readFileSync('/etc/rixxx-panel/config.json', 'utf8'));
const dbPath = cfg.dbPath || '/var/lib/rixxx-panel/db.sqlite';

let users = [];
try {
  const db = new Database(dbPath, { readonly: true });
  users = db.prepare('SELECT username, password, protocols FROM users').all()
    .filter(u => {
      try {
        return JSON.parse(u.protocols || '["naive","mieru"]').includes('naive');
      } catch {
        return true;
      }
    })
    .filter(u => (u.password || '').trim())
    .map(u => ({ username: u.username, password: u.password }));
  db.close();
} catch (e) {
  users = [];
}

const out = tpl.render({
  adminEmail: cfg.adminEmail || '',
  domain: cfg.domain || 'localhost',
  naivePort: cfg.naivePort || 443,
  fakeSiteDir: cfg.fakeSiteDir || '/var/www/fake-site',
  probeSecret: cfg.probeSecret || '',
  probeMode: cfg.probeMode || 'bare',
  logFile: '/var/log/caddy-naive/access.log',
  upstream: (cfg.cascadeEnabled && cfg.cascadeNaiveUpstream) ? cfg.cascadeNaiveUpstream : '',
}, users);

process.stdout.write(out);
NODE

  "$CADDY_BIN" validate --config /tmp/Caddyfile.rixxx-panel-8080 --adapter caddyfile

  cp /tmp/Caddyfile.rixxx-panel-8080 "$CADDY_FILE"

  if id caddy &>/dev/null; then
    chown root:caddy "$CADDY_FILE" || true
  fi
  chmod 640 "$CADDY_FILE" || true

  "$CADDY_BIN" fmt --overwrite "$CADDY_FILE" || true
  "$CADDY_BIN" validate --config "$CADDY_FILE" --adapter caddyfile

  log "Caddyfile успешно перегенерирован"
}

fix_permissions() {
  log "Восстанавливаем права для caddy-naive"

  if id caddy &>/dev/null; then
    chown -R root:caddy /etc/caddy-naive 2>/dev/null || true
  fi

  chmod 750 /etc/caddy-naive 2>/dev/null || true
  find /etc/caddy-naive -type d -exec chmod 750 {} \; 2>/dev/null || true
  find /etc/caddy-naive -type f -exec chmod 640 {} \; 2>/dev/null || true

  mkdir -p /var/log/caddy-naive /var/lib/caddy

  if id caddy &>/dev/null; then
    chown -R caddy:caddy /var/log/caddy-naive /var/lib/caddy 2>/dev/null || true
  fi

  chmod 755 /var/log/caddy-naive 2>/dev/null || true
  chmod 700 /var/lib/caddy 2>/dev/null || true

  chown root:caddy "$CADDY_BIN" 2>/dev/null || true
  chmod 755 "$CADDY_BIN" 2>/dev/null || true
  setcap 'cap_net_bind_service=+ep' "$CADDY_BIN" 2>/dev/null || true
}

open_firewall() {
  if command -v ufw &>/dev/null; then
    log "Открываем порт ${PANEL_PUBLIC_PORT}/tcp в UFW"
    ufw allow "${PANEL_PUBLIC_PORT}/tcp" comment "Panel Web UI via Caddy" 2>/dev/null || true
    ufw reload 2>/dev/null || true
  else
    warn "ufw не найден, пропускаю настройку firewall"
  fi
}

restart_services() {
  log "Перезапускаем панель через PM2"

  cd "$PANEL_DIR"

  if command -v pm2 &>/dev/null; then
    pm2 delete panel-naive-mieru 2>/dev/null || true

    NODE_ENV=production PANEL_HOST="${PANEL_INTERNAL_HOST}" PANEL_PORT="${PANEL_INTERNAL_PORT}" \
      pm2 start "${PANEL_DIR}/server/index.js" \
      --name panel-naive-mieru \
      --cwd "$PANEL_DIR" \
      --log /var/log/panel-naive-mieru.log \
      --time

    pm2 save || true
  else
    warn "pm2 не найден, пропускаю перезапуск панели"
  fi

  log "Перезапускаем caddy-naive"

  systemctl daemon-reload || true
  systemctl reset-failed caddy-naive 2>/dev/null || true
  systemctl restart caddy-naive
}

verify() {
  log "Проверка портов"
  ss -tlnp | grep -E ':8080|:3000|:443|:80' || true

  log "Проверка ответа панели через Caddy"
  if curl -I --max-time 8 "http://127.0.0.1:${PANEL_PUBLIC_PORT}/" 2>/tmp/panel-8080-curl.err; then
    echo ""
    log "Проверка security headers через :${PANEL_PUBLIC_PORT}"

    if curl -I --max-time 8 "http://127.0.0.1:${PANEL_PUBLIC_PORT}/" | grep -Ei 'Content-Security-Policy|Strict-Transport-Security|Cross-Origin-Opener-Policy|Cross-Origin-Resource-Policy'; then
      warn "Через :${PANEL_PUBLIC_PORT} всё ещё видны security headers. CSS/JS могут снова пытаться грузиться по HTTPS."
    else
      log "OK: проблемные security headers через :${PANEL_PUBLIC_PORT} не отдаются"
    fi
  else
    warn "Не удалось получить ответ от http://127.0.0.1:${PANEL_PUBLIC_PORT}/"
    cat /tmp/panel-8080-curl.err || true
  fi

  echo ""
  log "Готово."
  echo "Публичный URL панели:"
  echo "  http://SERVER_IP:${PANEL_PUBLIC_PORT}/"
  echo ""
  echo "После добавления/удаления пользователей теперь должен использоваться reload Caddy,"
  echo "а restart будет только fallback-ом."
}

main() {
  need_root
  check_files
  patch_caddy_template
  patch_reload_caddy
  regenerate_caddyfile
  fix_permissions
  open_firewall
  restart_services
  verify
}

main "$@"
