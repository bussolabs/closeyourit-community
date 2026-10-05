# Webhook in ingresso dai servizi esterni. Nessuna autenticazione utente: ognuno ha il proprio gate
# (header segreto o firma HMAC) verificato dal controller.

# Webhook inbound del bot Telegram ufficiale (canale Telegram::, rules/backend-channels.md). Nessuna
# auth utente: il gate è l'header X-Telegram-Bot-Api-Secret-Token (== ENV TELEGRAM_WEBHOOK_SECRET,
# impostato via secret_token su setWebhook). Path FISSO — nessun segreto nell'URL (che finirebbe nei log).
post "telegram/webhook" => "telegram/webhooks#create", as: :telegram_webhook

# Webhook inbound della GitHub App (canale Github::, rules/backend-channels.md). Nessuna auth utente:
# il gate è la firma HMAC X-Hub-Signature-256 (== HMAC-SHA256 del body con GITHUB_WEBHOOK_SECRET).
# Path FISSO — nessun segreto nell'URL.
post "github/webhook" => "github/webhooks#create", as: :github_webhook
