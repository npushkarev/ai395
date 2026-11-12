#!/usr/bin/env bash
# Быстрая модель для halogen: собственный чекпоинт v2 (peonist-ai/halogen-qwen3.8-flash-next).
# Против Uncensored GGUF: генерация ~54 т/с проза / ~73 код вместо ~30–36, промпт ~1700 т/с.
# Минус: это обычная модель, С цензурой.
#
#   ./halogen-fast.sh              # скачать v2 (~112 ГиБ, докачивает) и переключить halogen на неё
#   ./halogen-fast.sh download     # только скачать
#   ./halogen-fast.sh fast         # переключить на быструю (v2)
#   ./halogen-fast.sh uncensored   # переключить на Uncensored GGUF
#   ./halogen-fast.sh progress     # сколько осталось докачать (можно из другого терминала)
#   ./halogen-fast.sh status       # что сейчас крутится
set -Eeuo pipefail
# Ни одна ошибка не должна проходить молча: печатаем, где и что упало (130 = Ctrl+C, о нём уже сказано)
trap 'rc=$?; ((rc == 130)) || echo "✗ ошибка (код $rc): строка $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_env_saved=$(export -p)
[[ -f "$SCRIPT_DIR/ai395.conf" ]] && source "$SCRIPT_DIR/ai395.conf"
eval "$_env_saved"; unset _env_saved
: "${AI_HOME:=$HOME/ai395}" "${MODEL_DIR:=$HOME/models/qwen38unc}" "${TORCH_PYTHON:=3.12}"
: "${HG_WEIGHTS_REPO:=peonist-ai/halogen-qwen3.8-flash-next}" "${HF_HUB_PIN:=huggingface_hub==1.17.0}"

# v2 + таблица n-грамм + драфт-голова (нужна при переключении на GGUF) + vision-башня (картинки) + токенайзер
FILES=(
  qwen38-flash-next-v2.hgn
  qwen38-flash-next-ngram.hgn
  qwen38-flash-next-mtp.hgn
  qwen38-flash-next-vision.hgn
  tokenizer/chat_template.jinja tokenizer/generation_config.json tokenizer/merges.txt
  tokenizer/tokenizer.json tokenizer/tokenizer_config.json tokenizer/vocab.json
)
NEED_GIB=112
CHOICE_FILE="$AI_HOME/halogen.choice"
VENV="$AI_HOME/venv-tools"
LOG_DIR="$AI_HOME/logs"

ok()   { echo $'\e[32m✓\e[0m' "$*"; }
warn() { echo $'\e[33m!\e[0m' "$*"; }
die()  { echo $'\e[31m✗' "$*"$'\e[0m' >&2; exit 1; }

# sudo-rs (Ubuntu 26.04) помнит пароль 15 минут и ждёт ввода 5 минут, а загрузка идёт часами:
# без поддержки метки переключение halogen после неё упало бы на запросе пароля.
sudo_keepalive() {
  sudo -v || die "нужен sudo"
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 60; done ) &
  SUDO_KA_PID=$!
  trap 'kill "$SUDO_KA_PID" 2>/dev/null || true' EXIT
}

# venv с закреплённым huggingface_hub: 1.17.0 с HF_HUB_DISABLE_XET=1 докачивает прерванные файлы
# с того же места, а 1.18+ и 2.x начинают их заново (для 62-ГиБ файла это часы).
ensure_hf() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
  [[ -x "$VENV/bin/python" ]] || uv venv -q --python "$TORCH_PYTHON" "$VENV"
  uv pip install -q --python "$VENV/bin/python" "$HF_HUB_PIN"
}

# 2.x при обрыве оставлял <hash>.<etag>.<uuid8>.incomplete, которые никто не докачивает и не удаляет
clean_hf_orphans() {
  local d="$MODEL_DIR/.cache/huggingface/download" f
  [[ -d "$d" ]] || return 0
  if pgrep -u "$(id -u)" -f 'hf download' >/dev/null; then return 0; fi   # кто-то качает прямо сейчас
  while IFS= read -r -d '' f; do
    if [[ "$(basename "$f")" =~ \.[0-9a-f]{8}\.incomplete$ ]]; then rm -f "$f"; fi
  done < <(find "$d" -name '*.incomplete' -print0 2>/dev/null)
  return 0
}

# Контейнер halogen работает от root: если он что-то докачал в том, hf download от пользователя упадёт с PermissionError
fix_ownership() {
  if [[ -n "$(find "$MODEL_DIR" ! -user "$(id -u)" -print -quit 2>/dev/null || true)" ]]; then
    warn "в $MODEL_DIR есть файлы другого владельца (root из контейнера) — возвращаю их себе (sudo)"
    sudo chown -R "$(id -u):$(id -g)" "$MODEL_DIR"
  fi
  return 0
}

# hf download с понятным прогрессом: «скачано X из Y ГиБ · скорость · осталось ~N мин» раз в 20 с.
# Ctrl+C / закрытие окна останавливают и загрузку; повторный запуск докачает с того же места.
hf_get() {
  local repo=$1; shift
  HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_PROGRESS_BARS=1 \
    "$VENV/bin/hf" download "$repo" "$@" --local-dir "$MODEL_DIR" &
  local dl=$!
  local st="$LOG_DIR/download.status"
  mkdir -p "$LOG_DIR"
  DL_STATUS_FILE="$st" "$VENV/bin/python" "$SCRIPT_DIR/dl_progress.py" "$repo" "$MODEL_DIR" "$dl" "$@" &
  local mon=$!
  trap "kill $dl $mon 2>/dev/null; rm -f '$st'; echo; echo 'прервано — запусти ещё раз, докачает с того же места'; exit 130" INT TERM HUP
  local rc=0
  wait "$dl" || rc=$?
  kill "$mon" 2>/dev/null || true   # индикатор мог уже выйти сам
  wait "$mon" 2>/dev/null || true
  trap - INT TERM HUP
  rm -f "$st"
  ((rc == 0)) || die "загрузка $repo прервалась (код $rc) — запусти ещё раз, докачает с того же места"
}

download() {
  mkdir -p "$MODEL_DIR"
  clean_hf_orphans   # мусор прошлых прерванных попыток освобождает диск, даже если всё уже скачано
  local f missing=0
  for f in "${FILES[@]}"; do
    if [[ ! -f "$MODEL_DIR/$f" ]]; then missing=1; fi
  done
  if ((missing == 0)); then ok "быстрая модель уже скачана: $MODEL_DIR"; return 0; fi

  fix_ownership
  # сколько ещё докачать: размер минус готовые файлы и недокачанные куски
  local have_gib part_gib need_gib avail_gib
  have_gib=$( (du -scBG "$MODEL_DIR"/qwen38-flash-next-{v2,ngram}.hgn 2>/dev/null || true) | awk '$2=="total"{print $1+0}')
  part_gib=$( (du -sBG "$MODEL_DIR/.cache/huggingface/download" 2>/dev/null || true) | awk '{print $1+0}')
  need_gib=$(( NEED_GIB - ${have_gib:-0} - ${part_gib:-0} ))
  if (( need_gib < 1 )); then need_gib=1; fi
  avail_gib=$(df -BG --output=avail "$MODEL_DIR" | tail -1 | tr -dc 0-9)
  if (( avail_gib < need_gib + 5 )); then
    die "на диске свободно ${avail_gib} ГиБ, а нужно ещё ~${need_gib} ГиБ (+5 запаса). Освободи место: недокачанное лежит в $MODEL_DIR/.cache/huggingface/download, Uncensored GGUF — $MODEL_DIR/Qwen3.8-Flash-Next-Uncensored*.gguf"
  fi
  curl -sf -m 20 -o /dev/null "https://huggingface.co/api/models/$HG_WEIGHTS_REPO" \
    || die "нет доступа к huggingface.co — проверь интернет/прокси"
  [[ -s "$HOME/.cache/huggingface/token" ]] || warn "нет HF-токена (~/.cache/huggingface/token) — будет медленнее"
  if [[ -z "${TMUX:-}${STY:-}" ]]; then
    warn "загрузка долгая: если закрыть окно терминала, она прервётся (повторный запуск докачает). Надёжнее в tmux: tmux new -s ai395"
  fi
  echo "качаю $HG_WEIGHTS_REPO (~${need_gib} ГиБ; можно прервать Ctrl+C — докачает с того же места)…"
  ensure_hf
  hf_get "$HG_WEIGHTS_REPO" "${FILES[@]}"
  ok "быстрая модель скачана в $MODEL_DIR"
}

switch() {
  local choice=$1
  if [[ $choice == fast ]]; then
    [[ -f "$MODEL_DIR/qwen38-flash-next-v2.hgn" && -f "$MODEL_DIR/qwen38-flash-next-ngram.hgn" ]] \
      || die "v2 ещё не скачана: ./halogen-fast.sh download"
  fi
  mkdir -p "$AI_HOME"
  echo "$choice" >"$CHOICE_FILE"
  ok "выбрано: $choice — перезапускаю halogen"
  "$SCRIPT_DIR/setup-ai395.sh" halogen
}

status() {
  echo "выбор: $(cat "$CHOICE_FILE" 2>/dev/null || echo "${HG_MODEL:-fast} (из конфига)")"
  (ls -lh "$MODEL_DIR"/*.hgn "$MODEL_DIR"/*.gguf 2>/dev/null || true) | awk '{print "  "$5"\t"$9}'
  echo "диск: $(df -h --output=avail "$MODEL_DIR" | tail -1) свободно"
  local h
  h=$(curl -s -m 5 http://127.0.0.1:8731/health) || h="halogen не отвечает"
  echo "${h:0:400}"
}

case "${1:-all}" in
  all)        sudo_keepalive; download; switch fast ;;
  download)   download ;;
  fast)       switch fast ;;
  uncensored) switch uncensored ;;
  status)     status ;;
  progress)
    # Пока идёт загрузка (в этом или другом терминале), её индикатор пишет последнюю строку в файл
    st="$LOG_DIR/download.status"
    [[ -x "$VENV/bin/python" ]] || ensure_hf >/dev/null 2>&1
    if pgrep -u "$(id -u)" -f 'hf download' >/dev/null; then
      if [[ -s "$st" ]]; then cat "$st"
      else "$VENV/bin/python" "$SCRIPT_DIR/dl_progress.py" "$HG_WEIGHTS_REPO" "$MODEL_DIR" 0 "${FILES[@]}"; fi
    else
      "$VENV/bin/python" "$SCRIPT_DIR/dl_progress.py" "$HG_WEIGHTS_REPO" "$MODEL_DIR" -1 "${FILES[@]}"
    fi ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
