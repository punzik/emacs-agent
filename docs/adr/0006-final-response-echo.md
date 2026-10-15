# ADR-0006: Временный preview финального ответа в echo area

Статус: реализовано по запросу пользователя, проверено offline и локальным
preview smoke в работающем Emacs (без обращения к модели).

## Решение

Показывать финальный текст модели обычным `message`, без отдельного окна или
буфера. Это временное сообщение, которое сменяется следующим сообщением или
обычным вводом; отдельного таймера и sticky UI нет.

- `emacs-agent-final-response-lines`: максимум экранных строк, по умолчанию 3;
  0 отключает уведомление.
- `emacs-agent-final-response-part`: `start` по умолчанию, либо `end`.
- Перенос длинных строк учитывается по геометрии minibuffer window через
  публичный `vertical-motion`. Ellipsis входит в лимит; tabs раскрываются,
  text properties не переносятся в preview. Оригинальный текст не меняется.
- Используется последняя canonical assistant-запись именно завершённого run,
  не поиск любого предыдущего ответа. Пустой final после tool batch не должен
  повторно показывать промежуточный комментарий перед инструментами.
- Вывод только при successful completed, один раз, до старта следующего FIFO
  input. Reasoning, tools, partial deltas, failed/cancelled не уведомляют.
- `message` получает строку через `%s`; форматирующие знаки в ответе не
  интерпретируются. `message-log-max` локально nil: полного дубликата ответа в
  `*Messages*` нет. Window height/resize настройки меняются только динамически
  на время вызова; источник, окна, журнал, API history и snapshots не правятся.
- По дополнительному запросу пользователя дубликат подавляется, когда
  selected window показывает journal той же сессии. Проверяется реальное
  selected window, не current-buffer callback (обычно source/transport).
  Просто видимый фоновый journal, журнал другой сессии и instructions view
  не показывают этот final пользователю и не подавляют echo. Настройка
  не добавляется: это устранение дублирования, а не изменение preview limit.
- Ошибка echo/display не блокирует завершённый run и следующий input.
- Полный ответ остаётся в существующем journal/history. Уведомления не
  восстанавливаются и не повторяются при reopen/restore.

## Проверка

157 ERT и warnings-as-errors compilation прошли. Проверены начало/конец,
одна строка, Unicode wide/combining characters, tabs и wrapping boundary,
отсутствие изменений source/window state, временные настройки, `%`, пустой
final, tool commentary, нулевой opt-out, completed/failed/cancelled, duplicate
и late callbacks, полная canonical запись и порядок FIFO, включая сломанный
`message`. Длинные строки проверяются по screen rows, не только числу `\n`.
Параметризованная регрессия проверяет selected own journal, background journal,
other journal, agent-owned non-journal view и отсутствие journal; полный final
в canonical history сохраняется во всех случаях.
В работающем Emacs показан синтетический четырёхстрочный ответ: current-message
содержит первые три строки с `...`, echo-area height после redisplay = 3.
Model/transport contract, persistence schema и порядок этапов F2 не менялись.
