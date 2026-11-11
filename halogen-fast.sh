#!/usr/bin/env bash
# Быстрая модель для halogen: собственный чекпоинт v2 (peonist-ai/halogen-qwen3.8-flash-next).
# Против Uncensored GGUF: генерация ~54 т/с проза / ~73 код вместо ~30–36, промпт ~1700 т/с.
# Минус: это обычная модель, С цензурой.
#
#   ./halogen-fast.sh              # скачать v2 (~111 ГиБ, докачивает) и переключить halogen на неё
#   ./halogen-fast.sh download     # только скачать
#   ./halogen-fast.sh fast         # переключить на быструю (v2)
#   ./halogen-fast.sh uncensored   # переключить на Uncensored GGUF
#   ./halogen-fast.sh progress     # сколько осталось докачать (можно из другого терминала)
#   ./halogen-fast.sh status       # что сейчас крутится
set -Eeuo pipefail
# Ни одна ошибка не должна проходить молча: печатаем, где и что упало
trap 'echo "✗ ошибка: строка $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_env_saved=$(export -p)
[[ -f "$SCRIPT_DIR/ai395.conf" ]] && source "$SCRIPT_DIR/ai395.conf"
eval "$_env_saved"; unset _env_saved
: "${AI_HOME:=$HOME/ai395}" "${MODEL_DIR:=$HOME/models/qwen38unc}"
: "${HG_WEIGHTS_REPO:=peonist-ai/halogen-qwen3.8-flash-next}"

# v2 + таблица n-грамм + драфт-голова + vision-башня (картинки) + токенайзер
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

ok()   { echo $'\e[32m✓\e[0m' "$*"; }
warn() { echo $'\e[33m!\e[0m' "$*"; }
die()  { echo $'\e[31m✗' "$*"$'\e[0m' >&2; exit 1; }

hf_bin() {
  local hf="$AI_HOME/venv-tools/bin/hf"
  if [[ ! -x "$hf" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
    {
      command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
      uv venv -q --python 3.12 "$AI_HOME/venv-tools"
      uv pip install -q --python "$AI_HOME/venv-tools/bin/python" "huggingface_hub[cli,hf_xet]"
    } >&2   # stdout этой функции — только путь к hf
  fi
  echo "$hf"
}

# hf download с понятным прогрессом: «скачано X из Y ГиБ · скорость · осталось ~N мин» раз в 20 с.
# Ctrl+C останавливает и загрузку (фоновые процессы скрипта SIGINT сами не получают).
hf_get() {
  local repo=$1; shift
  HF_HUB_DISABLE_PROGRESS_BARS=1 "$HF" download "$repo" "$@" --local-dir "$MODEL_DIR" &
  local dl=$!
  mkdir -p "$AI_HOME/logs"
  DL_STATUS_FILE="$AI_HOME/logs/download.status" \
    "$AI_HOME/venv-tools/bin/python" "$SCRIPT_DIR/dl_progress.py" "$repo" "$MODEL_DIR" "$dl" "$@" &
  local mon=$!
  trap "kill $dl $mon 2>/dev/null; echo; echo 'прервано — запусти ещё раз, докачает'; exit 130" INT TERM
  local rc=0
  wait "$dl" || rc=$?
  kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null || true
  trap - INT TERM
  rm -f "$AI_HOME/logs/download.status"
  ((rc == 0)) || die "загрузка $repo прервалась (код $rc) — запусти ещё раз, докачает"
}

download() {
  mkdir -p "$MODEL_DIR"
  # сколько ещё докачать: размер минус уже лежащее
  local have_gib avail_gib
  have_gib=$( (du -scBG "$MODEL_DIR"/qwen38-flash-next-{v2,ngram}.hgn 2>/dev/null || true) | awk '$2=="total"{print $1+0}')
  have_gib=${have_gib:-0}
  avail_gib=$(df -BG --output=avail "$MODEL_DIR" | tail -1 | tr -dc 0-9)
  if (( avail_gib < NEED_GIB - have_gib + 5 )); then
    die "на диске свободно ${avail_gib} ГиБ, а нужно ещё ~$(( NEED_GIB - have_gib )) ГиБ. Освободи место (например, удали $MODEL_DIR/*.qsa.gguf)."
  fi
  [[ -s "$HOME/.cache/huggingface/token" ]] || warn "нет HF-токена (~/.cache/huggingface/token) — будет медленнее"
  echo "качаю $HG_WEIGHTS_REPO (~$(( NEED_GIB - have_gib )) ГиБ осталось; можно прервать Ctrl+C — докачает)…"
  HF=$(hf_bin)
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
  curl -s -m 5 http://127.0.0.1:8731/health | head -c 400 || echo "halogen не отвечает"; echo
}

case "${1:-all}" in
  all)        download; switch fast ;;
  download)   download ;;
  fast)       switch fast ;;
  uncensored) switch uncensored ;;
  status)     status ;;
  progress)
    # Пока идёт загрузка (в этом или другом терминале), её индикатор пишет последнюю строку в файл
    st="$AI_HOME/logs/download.status"
    if [[ -s "$st" ]] && pgrep -f 'hf download' >/dev/null; then
      cat "$st"
    else
      hf_bin >/dev/null
      "$AI_HOME/venv-tools/bin/python" "$SCRIPT_DIR/dl_progress.py" "$HG_WEIGHTS_REPO" "$MODEL_DIR" 0 "${FILES[@]}"
    fi ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
