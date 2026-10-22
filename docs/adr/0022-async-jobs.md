# ADR-0022: Локальные асинхронные process jobs

Статус: согласовано пользователем, реализовано; verification ниже.

## Граница

Обычные Elisp helpers через единственный `eval_elisp`, не новые model tools.
Локальные процессы через `make-process`; без TRAMP, shell-обёртки, таймеров,
автоматического polling или продолжения LLM. Нет save, retry, интерпретации
успеха, отката эффектов или восстановления после restart. Синхронный
`emacs-agent-run-process` сохраняет прежний контракт.

Jobs общие для текущего Emacs, не разделяют полномочия сессий. ID содержит
runtime namespace и монотонный счётчик: старый ID не адресует новую job после
restart. Отмена run не
отменяет jobs автоматически: управление явное по ID. Процессы и результаты
не включаются в snapshots conversation; записанный в историю ID после restart
не является действующей job.

## API

- `emacs-agent-job-start PROGRAM ARGS &key (directory default-directory)` → ID.
  Literal argv (list/vector строк), bare names через PATH, executable с
  directory-компонентом относительно cwd. Remote program/cwd отклоняются до
  запуска. Output декодируется как UTF-8; stdout/stderr объединены в pipe
  (порядок отдельных записей разных потоков не гарантируется).
- `emacs-agent-job-status ID` → plist: `:id`, `:state` (`running`, `exited`,
  `signaled`, `failed`), `:command`, `:directory`, `:created-at`, `:finished-at`,
  `:cancel-requested`, `:exit` (integer только при обычном exit), `:signal`
  (номер сигнала), `:output-size`, `:output-available`. Нет ожидания завершения.
- `emacs-agent-job-read ID &key (from 0) (limit 4096)` → metadata статуса плюс
  `:text`, `:from`, `:next-offset`, `:truncated`, `:complete`. Смещения нулевые,
  в символах декодированного текста; продолжать с `:next-offset`. `:truncated`
  означает непрочитанный вывод, доступный сейчас; nil не означает завершения.
  `:complete` истинно только для terminal job при достижении конца вывода.
  Печатный результат подгоняется под eval budget без stdout/wrappers; слишком
  маленький budget — ошибка. Чтение не потребляет и не меняет накопленный вывод.
- `emacs-agent-job-cancel ID` → status. Запрос отмены отмечается до
  `delete-process` сохранённого process object; повтор безопасен. Не ищет по
  PID/имени и не управляет посторонними процессами. Не обещает остановку дерева
  потомков, полноту вывода при принудительной отмене или отмену прошлых эффектов.
  Отмена не подменяет фактический exit/signal статус.
- `emacs-agent-job-list &key (from 0) (limit 20)` → `:jobs` (status plists,
  новые первыми), `:total`, `:next-offset`, `:truncated`. Страница вписывается
  в eval budget; offset относится к текущему списку, не стабильному snapshot.
- `emacs-agent-job-forget ID` → t. Только terminal job: удалить запись и
  приватный output buffer. Не удаляет файлы, созданные командой.

Полный вывод остаётся в приватном append-only буфере без undo до `forget` или
restart. Bounded read не ограничивает память; quotas, disk spooling и cleanup
по таймеру не входят в этот slice. Внешнее уничтожение output buffer явно
обозначается как unavailable; потерянный текст не подменяется пустой строкой.

## Lifecycle

Собственные filter/sentinel передаются непосредственно в `make-process`.
Job подготовлена до запуска; sentinel быстрого процесса не зависит от ещё
не присвоенного process field. Terminal sentinel идемпотентен, не добавляет
служебного текста в output. При нормальном завершении использована штатная
гарантия Emacs обработки вывода до terminal sentinel; ожидание всех потомков
с унаследованными pipe не обещается. Ошибка/quit запуска удаляет частичные
runtime ресурсы без retry. Status/read не запускают event loop и не ждут.

## Проверка

402 ERT (15 новых job tests и один prompt contract), warnings-as-errors
compilation и diff-check проходят через Nix `make clean test compile`.
Настоящие локальные процессы и deadline + `accept-process-output` покрывают
literal argv/cwd/PATH, stderr/Unicode/final chunk, чтение во время работы и
после exit, cancel/idempotence, cleanup при launch error/quit, remote rejection
до I/O, независимость jobs и сохранность source buffer, printed budget и
lossless continuation, pagination, unavailable output и копирование metadata.
Actual `emacs-agent-eval` с `texts` проверяет start/read без shell injection и
изменений source. Изоляция runtime namespaces проверена на пустом registry с
обнулённым counter. Prompt — 5846 символов (<5900), не token metric.

Независимый read-only review lifecycle не нашёл подтверждённых проблем;
отдельный batch probe проверил 80 быстрых завершений с Unicode stdout/stderr.
Provider calls, live user-Emacs и benchmark поведения LLM не выполнялись.
