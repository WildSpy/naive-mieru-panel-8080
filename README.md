# naive-mieru-panel-8080

Post-install фикс для панели **Panel Naive + Mieru by RIXXX**.

Скрипт исправляет публичный доступ к веб-панели на порту `8080` после установки панели.

## Что делает скрипт

`fix-panel-8080.sh`:

- добавляет в `caddyTemplate.js` reverse proxy для панели:

```text
:8080 → 127.0.0.1:3000
```

- оставляет саму Node.js-панель слушать только локально:

```text
127.0.0.1:3000
```

- открывает публичный доступ через Caddy:

```text
http://SERVER_IP:8080/
```

- удаляет проблемные HTTP-заголовки на `8080`, из-за которых браузер может пытаться грузить `style.css` и `app.js` через HTTPS:

```text
Content-Security-Policy
Strict-Transport-Security
Cross-Origin-Opener-Policy
Cross-Origin-Embedder-Policy
Cross-Origin-Resource-Policy
```

- меняет поведение панели при добавлении/удалении пользователей:
    - сначала используется мягкий reload Caddy:

```bash
systemctl reload caddy-naive
```

- если reload не сработал, выполняется fallback на restart:

```bash
systemctl restart caddy-naive
```

- перегенерирует текущий `/etc/caddy-naive/Caddyfile`;
- открывает порт `8080/tcp` в UFW, если UFW установлен;
- перезапускает `panel-naive-mieru` через PM2 и `caddy-naive`.

## Установка и запуск

После установки основной панели выполни:

```bash
curl -fsSL https://raw.githubusercontent.com/WildSpy/naive-mieru-panel-8080/main/fix-panel-8080.sh | sudo bash
```

## Важно

Скрипт рассчитан на стандартные пути установки:

```text
/opt/panel-naive-mieru
/etc/rixxx-panel/config.json
/etc/caddy-naive/Caddyfile
/usr/local/bin/caddy-naive
```

Запускать скрипт нужно от `root` или через `sudo`.
