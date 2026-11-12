#!/usr/bin/env python3
"""Сколько осталось докачать с Hugging Face в --local-dir.

  dl_progress.py <repo> <local_dir> <pid> <файл>...   # печатать раз в 20 с, пока жив процесс pid
  dl_progress.py <repo> <local_dir> 0 <файл>...       # загрузка идёт: замер скорости за 10 с и выход
  dl_progress.py <repo> <local_dir> -1 <файл>...      # загрузка не идёт: сколько уже лежит на диске

Готовое = целые файлы + недокачанные куски <hash>.<etag>.incomplete в <local_dir>/.cache/huggingface/download.
Скрипты качают без xet (HF_HUB_DISABLE_XET=1), поэтому .incomplete растёт по мере загрузки и счёт точный.
Сироты huggingface_hub 2.x (<hash>.<etag>.<uuid8>.incomplete) не считаются: их никто не докачивает.
Если задан DL_STATUS_FILE, последняя строка пишется ещё и туда (для `halogen-fast.sh progress`).
"""
import glob
import os
import re
import sys
import time
from pathlib import Path

from huggingface_hub import HfApi

INTERVAL = 20
GIB = 2 ** 30
ORPHAN = re.compile(r"\.[0-9a-f]{8}\.incomplete$")


def main() -> int:
    repo, local, pid, files = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
    status_file = os.environ.get("DL_STATUS_FILE")
    try:
        sizes = {p.path: (p.size or 0) for p in HfApi().get_paths_info(repo, files)}
    except Exception as e:  # нет сети — молча выходим, сама загрузка от этого не страдает
        print(f"(прогресс недоступен: {e})", flush=True)
        return 0
    total = sum(sizes.values())

    try:
        from huggingface_hub._local_folder import get_local_download_paths

        def partial(f: str) -> int:
            pattern = str(get_local_download_paths(local, f).incomplete_path("*"))
            s = 0
            for x in glob.glob(pattern):
                if ORPHAN.search(x):
                    continue
                try:
                    s += os.stat(x).st_blocks * 512
                except OSError:  # файл переименовали между glob и stat — значит, он уже готов
                    pass
            return s
    except Exception:
        def partial(f: str) -> int:
            return 0

    def on_disk() -> int:
        s = 0
        for f, size in sizes.items():
            p = local / f
            try:
                if p.stat().st_size == size:
                    s += size
                    continue
            except OSError:
                pass
            s += min(partial(f), size)
        return s

    def alive() -> bool:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def line(d: int, speed: float, idle: bool = False) -> str:
        out = f"⏬ скачано {d / GIB:6.1f} из {total / GIB:.1f} ГиБ ({100 * d / max(total, 1):4.1f}%)"
        if d >= total:
            return out + " · готово"
        if idle:
            return out + " · загрузка сейчас не идёт (запусти ./halogen-fast.sh download — докачает)"
        if speed > 50 * 1024:
            h, m = divmod(int((total - d) / speed // 60), 60)
            out += f" · {speed / 2**20:5.1f} МБ/с · осталось ~{f'{h} ч ' if h else ''}{m} мин"
        else:
            out += " · жду данные…"
        return out

    def emit(text: str) -> None:
        print(text, flush=True)
        if status_file:
            try:
                Path(status_file).write_text(f"{time.strftime('%H:%M:%S')}  {text}\n")
            except OSError:
                pass

    if pid == -1:
        print(line(on_disk(), 0, idle=True), flush=True)
        return 0
    if pid == 0:
        a = on_disk(); time.sleep(10); b = on_disk()
        print(line(b, (b - a) / 10), flush=True)
        return 0

    history = [(time.time(), on_disk())]
    while alive():
        time.sleep(INTERVAL)
        now, d = time.time(), on_disk()
        history = (history + [(now, d)])[-4:]  # скорость за последнюю минуту
        t0, d0 = history[0]
        emit(line(d, (d - d0) / max(now - t0, 1)))
        if d >= total:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
