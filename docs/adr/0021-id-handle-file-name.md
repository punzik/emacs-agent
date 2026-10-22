# ADR-0021: Один handle — hex-часть ID — для short и имени файла

Статус: согласовано пользователем, реализовано; verification ниже.

## Причина

Пользователь обнаружил два несоответствия в цепочке идентификации conversation:

1. short в информации/журнале был sha256 от всего ID — третий хэш, визуально
   не связанный с ID `session-<64hex>`.
2. После первого исправления (short = hex ID) осталось главное: имя файла
   снапшота было `sha256(ID).eld` — ещё один посторонний хэш, поэтому на диске
   не находилось ничего похожего на отображаемый ID.

Корень — двойное хэширование: ID уже содержит 64-hex хэш от параметров
создания, а store хэшировал ID повторно. Единый источник устранил обе
несостыковки: **handle = hex-часть canonical ID**.

## Решение

`emacs-agent-store-id-handle (ID)` в store.el: canonical ID
`session-<64hex>` → сам этот hex; любой другой формат → прежний sha256-fallback.
Используется в двух местах:

- `emacs-agent-store--file`: `conversations/<handle>.eld` — имя файла теперь
  совпадает с hex-частью ID;
- `emacs-agent-session-id-handle` (session.el, тонкая делегация) для short-ID
  в `emacs-agent-session-info`, picker-меток и journal/session names.

Итоговая картина согласована:

```
ID:    session-ecd2711c34cf…
short: ecd2711c34
file:  conversations/ecd2711c34cf….eld
```

Handle — только отображение и имя файла: identity, ключи registry, валидация
restore и сохранённое поле :id остаются полным ID. Коллизии в picker
по-прежнему разрешаются удлинением префикса. Неканонические ID (legacy/тесты)
сохраняют sha256-fallback, поэтому прежние тесты-фикстуры с ID вида
"one"/"info-session" не затронуты.

## Границы и последствия

Обратная совместимость со старыми сессиями не требуется (подтверждено
пользователем при ревью). Migration и fallback на прежнее имя файла не
выполняются.

Restore перечисляет все `.eld` в `conversations/` и валидирует как содержимое,
так и соответствие имени файла текущему handle. Поэтому snapshots canonical
ID, сохранённые по прежней схеме `sha256(ID).eld`, отвергаются с warning.
Selection pointers (`selections/<sha256 root>.eld`) сохраняют прежний формат,
но восстановление их целей ищет только новый путь `<hex>.eld`; если есть
только старый snapshot, восстановление завершается ошибкой. Для нового
формата следует использовать новый каталог данных.

## Проверка

386 ERT, warnings-as-errors compilation, diff-check. Регрессия: canonical ID →
short = префикс hex ID, `:saved-file` = `conversations/<hex ID>.eld`, session
name оканчивается на тот же short; legacy ID → sha256-fallback и в handle,
и в имени файла. Существующие store/fork/session тесты используют
`emacs-agent-store--file` для путей и потому проверены без правок. Без
provider calls, live user-Emacs или replay приватных данных.