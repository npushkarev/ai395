#!/usr/bin/env bash
# Запустить halogen на уже скачанной модели — без остальных шагов установки.
#
#   ./halogen-start.sh
#
# Если в другом окне ещё работает прошлый запуск (дописывает модель на диск или ждёт пароль),
# скрипт дождётся его конца, показывая, сколько реально лежит на диске, и потом поднимет halogen.
set -Eeuo pipefail
trap 'rc=$?; ((rc == 130)) || echo "✗ ошибка (код $rc): строка $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_env_saved=$(export -p)
[[ -f "$SCRIPT_DIR/ai395.conf" ]] && source "$SCRIPT_DIR/ai395.conf"
eval "$_env_saved"; unset _env_saved
: "${AI_HOME:=$HOME/ai395}" "${MODEL_DIR:=$HOME/models/qwen38unc}" "${HG_MODEL:=fast}"
: "${MODEL_FILE:=Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf}"

ok()   { echo $'\e[32m✓\e[0m' "$*"; }
warn() { echo $'\e[33m!\e[0m' "$*"; }
die()  { echo $'\e[31m✗' "$*"$'\e[0m' >&2; exit 1; }

# прошлый запуск: загрузка (hf) или сами скрипты установки в другом окне
# точные шаблоны: процесс hf из venv и bash, выполняющий наши скрипты; не сервер tmux, в чьей командной строке они тоже бывают
others() {
  pgrep -u "$(id -u)" -f '(bin|libexec)/hf download' 2>/dev/null || true
  pgrep -u "$(id -u)" -f '^(/usr/bin/|/bin/)?bash [^ ]*(setup-ai395|halogen-fast)\.sh' 2>/dev/null || true
}
downloading() { pgrep -u "$(id -u)" -f '(bin|libexec)/hf download' >/dev/null 2>&1; }
disk_kib() { (du -sk "$MODEL_DIR" 2>/dev/null || echo 0) | awk '{print $1+0}'; }

if [[ -n "$(others)" ]]; then
  warn "в другом окне ещё работает прошлый запуск — жду его конца (раз в 30 с покажу, что на диске)"
  echo "   Ничего там не прерывай, пока идёт загрузка: старая версия не умеет докачивать."
  prev=$(disk_kib); still=0
  while [[ -n "$(others)" ]]; do
    sleep 30
    cur=$(disk_kib)
    if downloading; then
      rate=$(( (cur - prev) / 1024 / 30 ))
      echo "   ⏬ на диске $(( cur / 1048576 )) ГиБ из ~112, прибавляется ${rate} МБ/с"
      if (( cur > prev )); then still=0; else still=$(( still + 1 )); fi
      if (( still == 20 )); then
        warn "10 минут на диске ничего не прибавляется — загрузка, похоже, зависла."
        warn "тогда: Ctrl+C в окне старого запуска, затем ./setup-ai395.sh (новая версия докачает недостающее)"
      fi
    elif [[ -n "$(others)" ]]; then
      echo "   загрузка закончилась; прошлый запуск идёт дальше (наверное, ждёт пароль sudo)."
      echo "   Если в его окне спрашивают пароль — нажми там Ctrl+C: дальше всё сделаю я."
    fi
    prev=$cur
  done
  ok "прошлый запуск закончился"
fi

choice=$(cat "$AI_HOME/halogen.choice" 2>/dev/null || echo "$HG_MODEL")
if [[ "$choice" == fast ]]; then
  missing=()
  for f in qwen38-flash-next-v2.hgn qwen38-flash-next-ngram.hgn tokenizer/tokenizer.json; do
    if [[ ! -f "$MODEL_DIR/$f" ]]; then missing+=("$f"); fi
  done
  if ((${#missing[@]})); then
    die "модель скачана не полностью, нет: ${missing[*]}. Запусти ./setup-ai395.sh — докачает недостающее и запустит halogen."
  fi
  ok "модель на месте: $(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1) в $MODEL_DIR"
elif [[ ! -f "$MODEL_DIR/$MODEL_FILE" ]]; then
  die "выбрана модель uncensored, но $MODEL_FILE не скачан: ./halogen-fast.sh uncensored"
fi

# Только запуск halogen (Docker, числовые GID устройств, ключ API, ожидание готовности) и итоговая проверка
exec "$SCRIPT_DIR/setup-ai395.sh" halogen verify
