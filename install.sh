#!/usr/bin/env bash
# Установка бота барбершопа на сервер с Ubuntu 22.04/24.04 или Debian 12. Запускается один раз:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/mfbzh/kremen-barbershop/main/install.sh)
#
# Что делает:
#   1. ставит Python и git;
#   2. проверяет, что сервер видит Telegram;
#   3. подключает приватный репозиторий с кодом по ключу только для чтения;
#   4. ставит зависимости бота;
#   5. спрашивает токен бота и Telegram ID администратора;
#   6. запускает бота службой (сам поднимается после сбоя и перезагрузки) и включает
#      автообновление из GitHub каждые 5 минут (deploy/update.sh).
# Повторный запуск безопасен: уже сделанные шаги пропускаются, настройки не затираются.
set -euo pipefail

REPO="${REPO:-git@github.com:mfbzh/coffee-voskhod.git}"
REPO_PAGE="${REPO_PAGE:-https://github.com/mfbzh/coffee-voskhod}"
BRANCH="${BRANCH:-main}"
USER_NAME=kremen
HOME_DIR="${HOME_DIR:-/opt/kremen}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
TTY="${TTY:-/dev/tty}" # откуда читать ответы; при запуске через bash <(curl ...) stdin занят
APP_DIR=$HOME_DIR/app
VENV=$HOME_DIR/venv
BOT_DIR=$APP_DIR/barbershop
KEY=$HOME_DIR/.ssh/github
SSH_CMD=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() {
    printf '\n\033[31mОшибка: %s\033[0m\n' "$*" >&2
    exit 1
}
ask() {
    local answer
    read -r -u 3 -p "$1" answer || true
    printf '%s' "$answer" | tr -d '[:space:]'
}
as_app() { runuser -u "$USER_NAME" -- env HOME="$HOME_DIR" "$@"; }

github_access_ok() {
    local out
    out="$(as_app "${SSH_CMD[@]}" -T git@github.com 2>&1 || true)"
    [[ $out == *"successfully authenticated"* ]]
}

bot_username() {
    curl -sS -m 15 "https://api.telegram.org/bot$1/getMe" 2>/dev/null |
        python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' \
            2>/dev/null || true
}

main() {
    [ "$(id -u)" -eq 0 ] || fail "запустите от имени root (или через sudo)"
    exec 3<"$TTY"
    command -v apt-get >/dev/null || fail "нужен сервер с Ubuntu или Debian"

    say "1/6 Ставлю Python и git"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git python3 python3-venv curl ca-certificates openssh-client >/dev/null

    say "2/6 Проверяю связь с Telegram"
    curl -sS -m 15 -o /dev/null https://api.telegram.org ||
        fail "сервер не может связаться с api.telegram.org. Выберите сервер в другой стране (например, Нидерланды или Германия) и запустите установку там"
    echo "Telegram доступен."

    say "3/6 Подключаю репозиторий с кодом"
    id "$USER_NAME" >/dev/null 2>&1 ||
        useradd --system --home-dir "$HOME_DIR" --create-home --shell /usr/sbin/nologin "$USER_NAME"
    install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/.ssh"
    [ -f "$KEY" ] || as_app ssh-keygen -q -t ed25519 -N "" -C "kremen-bot@$(hostname)" -f "$KEY"
    until github_access_ok; do
        echo
        echo "Серверу нужен доступ к коду бота только на чтение."
        echo "1. Откройте: $REPO_PAGE/settings/keys/new"
        echo "2. Title: server. В поле Key вставьте строку ниже целиком."
        echo "3. Галочку «Allow write access» НЕ ставьте. Нажмите «Add key»."
        echo
        cat "$KEY.pub"
        echo
        ask "Когда добавите ключ, нажмите Enter... " >/dev/null
    done
    echo "Доступ к GitHub есть."
    if [ ! -d "$APP_DIR/.git" ]; then
        as_app env GIT_SSH_COMMAND="${SSH_CMD[*]}" git clone --quiet "$REPO" "$APP_DIR" ||
            fail "не удалось скачать код из $REPO"
        as_app git -C "$APP_DIR" config core.sshCommand "${SSH_CMD[*]}"
    fi
    # При повторном запуске тоже берём свежую версию нужной ветки
    as_app git -C "$APP_DIR" fetch --quiet origin "$BRANCH" ||
        fail "в репозитории нет ветки $BRANCH"
    as_app git -C "$APP_DIR" checkout --quiet --force -B "$BRANCH" "origin/$BRANCH"
    [ -f "$BOT_DIR/bot/app.py" ] ||
        fail "в ветке $BRANCH нет кода бота (папки barbershop/bot). Влейте ветку с ботом в $BRANCH на GitHub или запустите установку так: BRANCH=имя-ветки bash install.sh"

    say "4/6 Ставлю зависимости бота"
    [ -d "$VENV" ] || as_app python3 -m venv "$VENV"
    as_app "$VENV/bin/pip" install --quiet --upgrade pip
    as_app "$VENV/bin/pip" install --quiet -r "$BOT_DIR/bot/requirements.txt"

    say "5/6 Настройки бота"
    local env_file=$BOT_DIR/bot/.env expected token username admins
    expected="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["telegram_bot"])' "$BOT_DIR/shop.json")"
    if [ -f "$env_file" ]; then
        echo "Настройки уже есть ($env_file), оставляю их."
    else
        while :; do
            token="$(ask "Токен бота (@BotFather → /mybots → @$expected → API Token): ")"
            username="$(bot_username "$token")"
            [ -n "$username" ] && break
            echo "Telegram не принял этот токен. Скопируйте его из @BotFather ещё раз."
        done
        if [ "${username,,}" != "${expected,,}" ]; then
            echo "Это токен от @$username, а кнопки на сайте ведут в @$expected."
            [ "$(ask 'Всё равно использовать его? Напишите да или нет: ')" = "да" ] ||
                fail "запустите установку заново и вставьте токен от @$expected"
        fi
        while :; do
            admins="$(ask "Ваш Telegram ID (узнать у @userinfobot), несколько — через запятую: ")"
            [[ $admins =~ ^[0-9]+(,[0-9]+)*$ ]] && break
            echo "Нужны только цифры, например 123456789"
        done
        (
            umask 077
            printf 'BOT_TOKEN=%s\nADMIN_IDS=%s\nBACKUP_TO_TELEGRAM=1\n' "$token" "$admins" >"$env_file"
        )
        chown "$USER_NAME:$USER_NAME" "$env_file"
    fi

    say "6/6 Запускаю бота и автообновление"
    cat >"$UNIT_DIR/kremen-bot.service" <<EOF
[Unit]
Description=Telegram-бот барбершопа: запись клиентов
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
WorkingDirectory=$BOT_DIR
ExecStart=$VENV/bin/python -m bot
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
    cat >"$UNIT_DIR/kremen-update.service" <<EOF
[Unit]
Description=Автообновление бота барбершопа из GitHub
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $BOT_DIR/deploy/update.sh
EOF
    cat >"$UNIT_DIR/kremen-update.timer" <<EOF
[Unit]
Description=Проверять обновления бота каждые 5 минут

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable kremen-bot >/dev/null 2>&1
    systemctl restart kremen-bot
    systemctl enable --now kremen-update.timer >/dev/null 2>&1
    sleep 10
    if ! systemctl is-active --quiet kremen-bot; then
        journalctl -u kremen-bot -n 30 --no-pager
        fail "бот не запустился, текст ошибки выше"
    fi

    say "Готово! Бот @${username:-$expected} работает круглосуточно."
    echo "Напишите ему /start. О каждой новой записи бот сообщит администратору."
    echo
    echo "Бот сам перезапускается после сбоев и перезагрузки сервера, раз в 5 минут"
    echo "проверяет обновления в GitHub, каждую ночь сохраняет копию базы записей,"
    echo "а по понедельникам присылает её вам в Telegram."
    echo
    echo "Полезные команды:"
    echo "  journalctl -u kremen-bot -f        журнал бота (выход: Ctrl+C)"
    echo "  systemctl restart kremen-bot       перезапустить бота"
    echo "  journalctl -u kremen-update -n 20  что делало автообновление"
}

main "$@"
