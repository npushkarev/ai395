#!/usr/bin/env python3
"""Чат с halogen прямо в терминале (только стандартная библиотека Python).

  ./chat.py                                    # быстрые ответы, без «размышлений»
  ./chat.py --think                            # модель сначала думает: точнее, но дольше
  HALOGEN_URL=http://192.168.1.50:8731 ./chat.py   # с другого компьютера (ключ — HALOGEN_API_KEY)

Команды в чате: /new — начать разговор заново, /think — включить/выключить размышления, /exit — выход.
Ctrl+C во время ответа — оборвать ответ, Ctrl+C или Ctrl+D на пустой строке — выйти.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

try:
    import readline  # noqa: F401 — стрелки и история ввода
except ImportError:
    pass

URL = os.environ.get("HALOGEN_URL", "http://127.0.0.1:8731").rstrip("/")
KEY_FILE = os.path.expanduser(os.environ.get("HALOGEN_KEY_FILE", "~/ai395/halogen.key"))
DIM, RST, BOLD, CYAN, RED = "\033[2m", "\033[0m", "\033[1m", "\033[36m", "\033[31m"


def api_key() -> str:
    k = os.environ.get("HALOGEN_API_KEY", "")
    if not k:
        try:
            with open(KEY_FILE) as fh:
                k = fh.read()
        except OSError:
            pass
    return k.strip()


def headers() -> dict:
    h = {"Content-Type": "application/json"}
    k = api_key()
    if k:
        h["Authorization"] = f"Bearer {k}"
    return h


def model_id() -> str:
    try:
        req = urllib.request.Request(URL + "/v1/models", headers=headers())
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)["data"][0]["id"]
    except Exception:
        return "halogen-qwen3.8-flash-next"


def ask(messages: list, model: str, think: bool) -> str:
    """Отправляет разговор, печатает ответ по мере генерации, возвращает текст ответа."""
    body = {
        "model": model,
        "messages": messages,
        "stream": True,
        "stream_options": {"include_usage": True},
        "max_tokens": 8192 if think else 4096,
        # у модели по умолчанию думать «на полную» (xhigh); для чата это долго
        "reasoning_effort": "medium" if think else "none",
    }
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(), headers=headers())
    t0 = time.time()
    first = None
    chunks = 0
    tokens = None
    answer = []
    in_thought = False
    try:
        with urllib.request.urlopen(req, timeout=3600) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    ev = json.loads(data)
                except ValueError:
                    continue
                usage = ev.get("usage") or {}
                if usage.get("completion_tokens"):
                    tokens = usage["completion_tokens"]
                for ch in ev.get("choices") or []:
                    d = ch.get("delta") or {}
                    thought = d.get("reasoning_content") or d.get("reasoning")
                    text = d.get("content")
                    if thought:
                        first = first or time.time()
                        if not in_thought:
                            sys.stdout.write(DIM + "(думает) ")
                            in_thought = True
                        sys.stdout.write(thought)
                        chunks += 1
                    if text:
                        first = first or time.time()
                        if in_thought:
                            sys.stdout.write(RST + "\n\n")
                            in_thought = False
                        sys.stdout.write(text)
                        answer.append(text)
                        chunks += 1
                sys.stdout.flush()
    except KeyboardInterrupt:
        sys.stdout.write(RST + f"\n{DIM}[ответ оборван]{RST}\n")
        return "".join(answer)
    finally:
        if in_thought:
            sys.stdout.write(RST)
    end = time.time()
    n = tokens or chunks
    if first:
        gen = max(end - first, 1e-6)
        print(f"\n{DIM}[{n} ток · {n / gen:.1f} ток/с · первый токен через {first - t0:.1f} с]{RST}")
    else:
        print(f"\n{DIM}[пустой ответ]{RST}")
    return "".join(answer)


def main() -> int:
    think = "--think" in sys.argv[1:]
    try:
        with urllib.request.urlopen(URL + "/health", timeout=10) as r:
            health = json.load(r)
    except Exception as e:
        print(f"{RED}halogen не отвечает на {URL}: {e}{RST}")
        print("проверь: sudo docker ps --filter name=halogen; sudo docker logs --tail 30 halogen")
        return 1
    model = health.get("model") or model_id()
    if not api_key():
        print(f"{DIM}ключ API не найден ({KEY_FILE}) — пробую без него{RST}")
    print(f"{BOLD}{model}{RST} на {URL} · размышления: {'вкл' if think else 'выкл'}")
    print(f"{DIM}/new — заново, /think — размышления вкл/выкл, /exit — выход{RST}")
    messages: list = []
    while True:
        try:
            q = input(f"\n{CYAN}вы>{RST} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not q:
            continue
        if q in ("/exit", "/quit", "exit"):
            return 0
        if q == "/new":
            messages = []
            print(f"{DIM}[новый разговор]{RST}")
            continue
        if q == "/think":
            think = not think
            print(f"{DIM}[размышления: {'вкл' if think else 'выкл'}]{RST}")
            continue
        messages.append({"role": "user", "content": q})
        print(f"{BOLD}модель>{RST} ", end="", flush=True)
        try:
            reply = ask(messages, model, think)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:500]
            print(f"{RED}ошибка {e.code}: {detail}{RST}")
            if e.code == 401:
                print(f"ключ: {KEY_FILE} (или задай HALOGEN_API_KEY)")
            messages.pop()
            continue
        except urllib.error.URLError as e:
            print(f"{RED}нет связи с halogen: {e.reason}{RST}")
            messages.pop()
            continue
        messages.append({"role": "assistant", "content": reply})


if __name__ == "__main__":
    sys.exit(main())
