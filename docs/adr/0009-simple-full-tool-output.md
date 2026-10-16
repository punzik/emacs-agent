# ADR-0009: Полный tool output — простой файл и tail preview

Статус: согласовано пользователем, реализовано и проверено offline.

## Решение и границы KISS

После изучения pigo пользователь выбрал минимальный F3 вместо первоначального
плана с отдельными stdout/value/error channels, artifact registry, helper/UI,
range API и автоматической очисткой.

`eval_elisp` по-прежнему возвращает обычную строку: stdout, затем `=> VALUE`
или маркированные ERROR/QUIT. Multiple forms, lexical eval, успешный nil,
строки без properties и уже выполненные эффекты сохраняют прежнюю семантику.
Новых advertised tools нет.

Если полный напечатанный результат превышает `emacs-agent-eval-output-limit`
(по умолчанию 32768 **символов**, не байтов/токенов):

1. После вычисления записать весь текст UTF-8 в уникальный `eval-*.txt` внутри
   `emacs-agent-data-directory/tool-output/`. Новые каталоги — 0700, файл — 0600.
2. Вернуть хвост и текстовое уведомление с quoted абсолютным путём. Notice
   входит в budget; если он один длиннее лимита, вернуть его целиком без tail.
   Равенство лимиту не вызывает запись файла.
3. При ошибке/quit записи удалить неполный файл best-effort и вернуть хвост
   с явным `full output unavailable` и причиной, без Full output reference.
   Вычисление **никогда не повторяется** ради сохранения. Ошибка сохранения не
   подменяет уже полученный value/error, хотя очень маленький budget может
   оставить только notice.

Пример:

```text
…хвост stdout…
=> 42
[truncated; showing tail. Full output: "/…/emacs-agent/tool-output/eval-….txt"]
```

Final value/error обычно сохраняется в tail после длинного stdout. Если сам
value/error больше доступного хвоста, его начало тоже может быть усечено;
гарантия целого результата относится к успешно записанному файлу, не preview.
Substring режется по Emacs characters, не внутри UTF-8 byte sequence. Quoted
path экранирует newline/quotes; строки уведомления не надо исполнять как код.

## Хранение и чтение

Общая настройка `emacs-agent-data-directory` перенесена из store в eval module,
где уже определена группа пакета. Имя, default и пользовательское значение
не меняются; standalone evaluator не требует загрузки store/gptel.

Файлы — обычные приватные нешифрованные данные. Читать нужные участки можно
штатным Elisp (`insert-file-contents` и buffer APIs) через существующий tool;
не `load`/eval сохранённого вывода. Ссылка — часть обычного tool-result string,
без новой схемы persistence/модельных полей или отдельного viewer.

Никакого registry, timers, quotas, startup scan или automatic cleanup. Файлы
остаются до ручного удаления; внешний cleanup/перенос data directory может
сделать старую ссылку недоступной. Отдельного recovery алгоритма нет.

В отличие от streaming spool pigo полный текст уже собран в памяти перед
записью. Это не ограничитель памяти/исполнения Elisp; прежняя synchronous
семантика сохраняется. UI display collapse и buffer-read continuation metadata
остаются независимыми от общего output overflow.

## Проверка

196 ERT и compilation с warnings-as-errors проходят. Девять новых тестов:
без overflow нет I/O, exact boundary, tail + full value, noisy stdout с nil/
error/quit, большой Unicode value и quoted path, tiny budget, create/write/quit
failure без повторного eval, удаление partial file, permissions и независимые
файлы без auto cleanup. Fixture directories приватные и удаляются тестами;
пользовательские исходники/журналы и модель не использовались.

В idle рабочий Emacs загружен только обновлённый compiled eval module (без
смены structs/очередей). Local smoke без HTTP: 2000 символов stdout и value 42,
preview ровно 300 characters, tail содержит value, полный файл equal исходному
тексту и mode 0600. Все smoke-файлы были во временном приватном каталоге и
удалены; настроенный пользовательский data-directory не менялся.
