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

Restore перечисляет все `.eld` в `conversations/` и валидирует по содержимому,
не по имени файла: файлы, сохранённые прежней схемой `sha256(ID).eld`,
продолжают загружаться. Migration не выполняется (глубокая alpha, прежнее
решение F6): уже сохранённые сессии при повторном сохранении записываются в
новый файл `<hex>.eld`; старый файл остаётся нетронутым, и обе копии одного
`:id` при загрузке дают обычную duplicate-изоляцию (warning). Пользователь
может удалить старые копии вручную. Selection pointers (`selections/<sha256
root>.eld`) не зависят от ID и не меняются.

## Проверка

386 ERT, warnings-as-errors compilation, diff-check. Регрессия: canonical ID →
short = префикс hex ID, `:saved-file` = `conversations/<hex ID>.eld`, session
name оканчивается на тот же short; legacy ID → sha256-fallback и в handle,
и в имени файла. Существующие store/fork/session тесты используют
`emacs-agent-store--file` для путей и потому проверены без правок. Без
provider calls, live user-Emacs или replay приватных данных.