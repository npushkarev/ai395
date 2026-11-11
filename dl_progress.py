#!/usr/bin/env python3
"""Сколько осталось докачать с Hugging Face в --local-dir.

  dl_progress.py <repo> <local_dir> <pid> <файл>...   # печатать раз в 20 с, пока жив процесс pid
  dl_progress.py <repo> <local_dir> 0 <файл>...       # один замер по файлам на диске и выход

Готовое = целые файлы + недокачанные куски в <local_dir>/.cache/huggingface/download.
hf_xet копит данные в памяти и пишет блоками, поэтому пока жив процесс загрузки, к тому, что
было на диске в начале, прибавляется принятое сетевыми картами (/proc/net/dev, только Linux;
на выделенном боксе это почти целиком наша загрузка).
Если задан DL_STATUS_FILE, последняя строка пишется ещё и туда (для `halogen-fast.sh progress`).
"""
import glob
import os
import sys
import time
from pathlib import Path

from huggingface_hub import HfApi

INTERVAL = 20
GIB = 2 ** 30


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
            return sum(os.stat(x).st_blocks * 512 for x in glob.glob(pattern))
    except Exception:
        def partial(f: str) -> int:
            return 0

    def on_disk() -> int:
        s = 0
        for f, size in sizes.items():
            p = local / f
            if p.exists() and p.stat().st_size == size:
                s += size
            else:
                s += min(partial(f), size)
        return s

    def received() -> int | None:
        # rx-байты всех физических/беспроводных интерфейсов (без lo, docker, veth, мостов)
        try:
            total_rx = 0
            with open("/proc/net/dev") as fh:
                for row in fh.readlines()[2:]:
                    name, data = row.split(":", 1)
                    name = name.strip()
                    if name == "lo" or name.startswith(("docker", "veth", "br-", "virbr", "tailscale", "wg")):
                        continue
                    total_rx += int(data.split()[0])
            return total_rx
        except (OSError, ValueError, IndexError):
            return None

    def alive() -> bool:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def line(d: int, speed: float) -> str:
        out = f"⏬ скачано {d / GIB:6.1f} из {total / GIB:.1f} ГиБ ({100 * d / max(total, 1):4.1f}%)"
        if d >= total:
            return out + " · готово"
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

    if pid == 0:
        a = on_disk(); time.sleep(10); b = on_disk()
        print(line(b, (b - a) / 10), flush=True)
        return 0

    base_disk, base_net = on_disk(), received()

    def done() -> int:
        d = on_disk()
        net = received()
        if base_net is not None and net is not None:
            d = max(d, base_disk + net - base_net)
        return min(d, total)

    history = [(time.time(), done())]
    while alive():
        time.sleep(INTERVAL)
        now, d = time.time(), done()
        history = (history + [(now, d)])[-4:]  # скорость за последнюю минуту
        t0, d0 = history[0]
        emit(line(d, (d - d0) / max(now - t0, 1)))
        if on_disk() >= total:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
