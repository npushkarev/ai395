#!/usr/bin/env bash
# Не даёт ПК уснуть: сервер моделей должен работать круглосуточно.
#
#   ./nosleep.sh          # запретить сон
#   ./nosleep.sh --undo   # вернуть как было
#   ./nosleep.sh --status # показать текущее состояние
#
# Экран при этом гаснуть может (это не мешает), а блокировка экрана остаётся.
# Запускать обычным пользователем из графической сессии (sudo спросит сам).
set -Eeuo pipefail
# Ни одна ошибка не должна проходить молча: печатаем, где и что упало
trap 'echo "✗ ошибка: строка $LINENO: $BASH_COMMAND" >&2' ERR

TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
LOGIND_CONF=/etc/systemd/logind.conf.d/90-ai395-nosleep.conf
GS=org.gnome.settings-daemon.plugins.power

ok()   { echo $'\e[32m✓\e[0m' "$*"; }
warn() { echo $'\e[33m!\e[0m' "$*"; }

gnome_set() {
  # gsettings нужен D-Bus графической сессии; по ssh без него просто пропускаем
  command -v gsettings >/dev/null && gsettings list-schemas 2>/dev/null | grep -qx "$GS" || return 1
  gsettings set "$GS" "$1" "$2" 2>/dev/null
}

status() {
  echo "systemd:"
  for t in "${TARGETS[@]}"; do printf '  %-30s %s\n' "$t" "$(systemctl is-enabled "$t" 2>/dev/null || true)"; done
  echo "logind: $( [[ -f $LOGIND_CONF ]] && echo "наш конфиг есть ($LOGIND_CONF)" || echo "по умолчанию")"
  if command -v gsettings >/dev/null && gsettings list-schemas 2>/dev/null | grep -qx "$GS"; then
    echo "GNOME: от сети — $(gsettings get $GS sleep-inactive-ac-type), от батареи — $(gsettings get $GS sleep-inactive-battery-type)"
  fi
  systemd-inhibit --list --no-pager 2>/dev/null | grep -i sleep || true
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --undo)
    sudo systemctl unmask "${TARGETS[@]}"
    sudo rm -f "$LOGIND_CONF"
    sudo systemctl kill -s HUP systemd-logind   # перечитать конфиг, не обрывая сессию
    gnome_set sleep-inactive-ac-type suspend && gnome_set sleep-inactive-battery-type suspend \
      && ok "GNOME: сон по простою возвращён" || true
    ok "сон снова разрешён"
    exit 0 ;;
  "") ;;
  *) echo "использование: $0 [--undo|--status]"; exit 2 ;;
esac

# 1. Сам сон: маскированные цели нельзя запустить ни кнопкой, ни по таймеру, ни из меню
sudo systemctl mask "${TARGETS[@]}" >/dev/null
ok "systemd: сон и гибернация заблокированы"

# 2. logind: не реагировать на простой, крышку и кнопку сна
sudo mkdir -p "$(dirname "$LOGIND_CONF")"
sudo tee "$LOGIND_CONF" >/dev/null <<'EOF'
[Login]
IdleAction=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
sudo systemctl kill -s HUP systemd-logind   # перезапуск logind выкинул бы из графической сессии
ok "logind: простой и кнопка сна игнорируются"

# 3. GNOME: не засыпать по простою (иначе он пишет в лог попытки уснуть)
if gnome_set sleep-inactive-ac-type nothing && gnome_set sleep-inactive-battery-type nothing; then
  ok "GNOME: автосон по простою выключен"
else
  warn "GNOME-настройки не тронуты (нет графической сессии) — не страшно, systemd всё равно не даст уснуть"
fi

echo
status
