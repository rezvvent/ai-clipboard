# AI Clipboard: полное развёртывание облачного backend

Эта инструкция разворачивает FastAPI, PostgreSQL и серверное подключение к
Google Gemini на Render. Backend и база работают на серверах Render, а не на
Mac пользователя. Клиент не создаёт локальную базу истории clipboard.

## 0. Сначала замените опубликованный Gemini API-ключ

Ключ, который однажды был отправлен в чат или вставлен в открытый текст,
необходимо считать скомпрометированным:

1. Откройте Google AI Studio → **API Keys**.
2. Отзовите старый ключ.
3. Создайте новый ключ.
4. Не вставляйте новый ключ в исходники, `Info.plist`, GitHub или приложение.
5. Новый ключ будет введён только в секрет `GEMINI_API_KEY` на Render.

## 1. Подготовьте закрытый Git-репозиторий

Render Blueprint разворачивается из GitHub или GitLab. В корне проекта уже
находятся `render.yaml`, `server/Dockerfile` и `.gitignore`.

Проверьте, что секрет не попадёт в коммит:

```bash
cd "/Users/rezvent/Documents/Codex/2026-07-25/files-mentioned-by-the-user-master"
git init
git status --short
git check-ignore -v server/.env
```

Последняя команда должна показать правило игнорирования. В `git status` не
должны присутствовать `server/.env`, `.build`, `outputs` или `work`.

Создайте на GitHub новый **Private repository**, не добавляя README и
`.gitignore` на стороне GitHub. Затем выполните команды, которые GitHub покажет
для существующего проекта, например:

```bash
git add .
git commit -m "Prepare AI Clipboard cloud deployment"
git branch -M main
git remote add origin https://github.com/ВАШ-ЛОГИН/ai-clipboard.git
git push -u origin main
```

Перед `git push` ещё раз выполните:

```bash
git status
git ls-files | grep -E '(^|/)\.env$' && echo "ОШИБКА: .env попал в Git"
```

Если вторая команда ничего не выводит, секретный `.env` не отслеживается.

## 2. Создайте Blueprint в Render

1. Войдите на <https://dashboard.render.com/>.
2. Подключите тот GitHub/GitLab-аккаунт, где находится закрытый репозиторий.
3. Нажмите **New → Blueprint**.
4. Выберите репозиторий `ai-clipboard`.
5. Оставьте путь Blueprint: `render.yaml`.
6. Render покажет два ресурса:
   - `ai-clipboard-api` — Docker web service;
   - `ai-clipboard-postgres` — постоянная PostgreSQL база.
7. В поле `GEMINI_API_KEY` вставьте новый ключ Google AI Studio.
8. Проверьте выбранные платные планы и итоговую стоимость.
9. Нажмите **Deploy Blueprint**.

Конфигурация создаёт ресурсы во Frankfurt, связывает `DATABASE_URL` через
приватную сеть Render и запрещает внешние подключения к PostgreSQL. Значения
`JWT_SECRET` и `SERVER_DATA_SECRET` Render генерирует автоматически.

Не изменяйте и не удаляйте `SERVER_DATA_SECRET` после появления данных:
изменение ключа сделает ранее сохранённые clipboard-объекты нечитаемыми.

## 3. Дождитесь успешного развёртывания

Откройте `ai-clipboard-api` → **Events/Logs**. Успешный запуск должен завершиться
статусом **Live**. При первом старте backend автоматически создаёт таблицы.

Скопируйте адрес сервиса, например:

```text
https://ai-clipboard-api-xxxx.onrender.com
```

Проверьте health endpoint:

```bash
curl --fail --show-error \
  "https://ai-clipboard-api-xxxx.onrender.com/healthz"
```

Ожидаемый ответ:

```json
{"status":"ok"}
```

Если health check не проходит:

1. Проверьте, что `GEMINI_API_KEY` задан в **Environment**.
2. Проверьте наличие `DATABASE_URL`, `JWT_SECRET` и `SERVER_DATA_SECRET`.
3. Не создавайте `DATABASE_URL` вручную — его даёт связанная база Render.
4. Посмотрите первую ошибку запуска в Logs, а не последующие перезапуски.

## 4. Встройте HTTPS-адрес в macOS-приложение

Откройте `Resources/Info.plist` и замените:

```xml
<key>AIClipboardAPIBaseURL</key>
<string>REPLACE_WITH_DEPLOYED_HTTPS_URL</string>
```

на реальный адрес без завершающего `/`:

```xml
<key>AIClipboardAPIBaseURL</key>
<string>https://ai-clipboard-api-xxxx.onrender.com</string>
```

Не вставляйте сюда Gemini-ключ, PostgreSQL URL, JWT secret или серверный ключ.

## 5. Соберите приложение

Для универсальной сборки нужен полный Xcode 15.4 или новее:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
cd "/Users/rezvent/Documents/Codex/2026-07-25/files-mentioned-by-the-user-master"
scripts/build-app.sh release
```

Готовое приложение появится здесь:

```text
.build/AI Clipboard.app
```

Для распространения среди других пользователей ad-hoc подписи недостаточно.
Нужны Apple Developer ID, hardened runtime и notarization.

## 6. Первая проверка

1. Переместите `AI Clipboard.app` в `/Applications`.
2. Запустите приложение.
3. В модальном окне нажмите **Добавить в автозапуск**.
4. Если macOS требует подтверждения, включите AI Clipboard в
   **Системные настройки → Основные → Объекты входа**.
5. Зарегистрируйте новый аккаунт с паролем не короче 12 символов.
6. Скопируйте уникальную строку на первом Mac.
7. Нажмите **Синхронизировать** и убедитесь, что нет ошибки.
8. Выйдите из аккаунта: история должна немедленно исчезнуть из RAM.
9. Войдите снова: история должна загрузиться с Render.
10. На втором устройстве установите ту же сборку и войдите в тот же аккаунт.
11. Откройте **ИИ поиск**, опишите старый элемент и проверьте ответ.

## 7. Проверка серверного хранения

В приложении не должно существовать локальных файлов:

```text
AIClipboard.sqlite
AIClipboard.sqlite-wal
AIClipboard.sqlite-shm
Objects/
protected-content.key
sync-master.key
```

Локально остаются только настройки интерфейса, метаданные текущего аккаунта и
токены серверной сессии. Текст, ссылки, изображения, поисковый индекс и ключ
шифрования clipboard локально не сохраняются.

## 8. Резервное копирование и эксплуатация

Для production:

1. Откройте PostgreSQL → **Recovery** и проверьте доступность point-in-time
   recovery.
2. Регулярно создавайте логические exports и храните копии отдельно.
3. Никогда не выводите request body и заголовок `x-goog-api-key` в логи.
4. Ограничьте права участников Render и GitHub.
5. Включите уведомления о сбоях и расходах.
6. Следите за квотой Gemini.
7. Перед публичным запуском добавьте email verification, восстановление пароля,
   rate limiting, аудит безопасности и процедуру ротации ключей.

## 9. Обновления

После изменения backend:

```bash
git add .
git commit -m "Update backend"
git push
```

Render автоматически пересоберёт сервис. Не меняйте
`AIClipboardAPIBaseURL`, если публичный URL сервиса остался прежним.
