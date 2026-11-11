#!/usr/bin/env python3
"""Включает QSA в GGUF Qwen3.8-Flash-Next: правит метаданные на месте, тензоры не трогает.

В кванте mradermacher `<arch>.attention.compress_ratios` = все нули (QSA выключено ошибкой
конвертации). Правильная раскладка: 4 на слоях il % 4 == 3, иначе 0. Запускать на КОПИИ файла.

  python qsa_patch.py model.qsa.gguf          # пропатчить
  python qsa_patch.py --check model.gguf      # только показать текущее значение
"""
import sys

from gguf import GGUFReader


def main() -> int:
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    if len(args) != 1:
        print(__doc__)
        return 2
    path = args[0]
    reader = GGUFReader(path, "r" if check else "r+")
    keys = [k for k in reader.fields if k.endswith(".attention.compress_ratios")]
    if not keys:
        print("compress_ratios не найден — у этой модели нет QSA, патч не нужен")
        return 0
    field = reader.fields[keys[0]]
    values = [int(field.parts[i][0]) for i in field.data]
    print(f"{keys[0]}: {len(values)} слоёв, сейчас {values}")
    if check:
        return 0
    if any(values):
        print("уже не нули — оставляю как есть")
        return 0
    for layer, idx in enumerate(field.data):
        field.parts[idx][0] = 4 if layer % 4 == 3 else 0
    reader.data.flush()
    print("готово:", [int(field.parts[i][0]) for i in field.data])
    return 0


if __name__ == "__main__":
    sys.exit(main())
