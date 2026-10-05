# frozen_string_literal: true

require "net/http"

# Registrazione one-time del webhook del bot ufficiale su Telegram (canale Telegram::). Da lanciare
# dopo aver creato il bot in BotFather e impostato TELEGRAM_BOT_TOKEN/TELEGRAM_WEBHOOK_SECRET su CYRA.
# Values may also come from Valhalla › Integrations (Settings::Integrations: Valhalla first, then ENV, CYRA-914).
# L'URL base viene da APP_BASE_URL o da MAIL_HOST (https). Telegram invia anche l'header
# X-Telegram-Bot-Api-Secret-Token = secret_token (difesa in più; il gate applicativo è il path :secret).
namespace :telegram do
  def telegram_api(method, params = {})
    token = Settings::Integrations.value(:telegram_bot_token) || raise(KeyError, "TELEGRAM_BOT_TOKEN")
    uri = URI("https://api.telegram.org/bot#{token}/#{method}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(params)
    http.request(request).body
  end

  # Variante con corpo JSON: setMyCommands richiede un array `commands` annidato (non form-encoded).
  def telegram_api_json(method, payload)
    token = Settings::Integrations.value(:telegram_bot_token) || raise(KeyError, "TELEGRAM_BOT_TOKEN")
    uri = URI("https://api.telegram.org/bot#{token}/#{method}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request.body = payload.to_json
    http.request(request).body
  end

  # Nomi dei comandi del menu Telegram: validi solo [a-z0-9_] (niente trattini). L'handler
  # (Telegram::HandleUpdate) accetta anche le varianti col trattino digitate a mano.
  def menu_command_names
    %w[nuovo_ticket progetti progetto ticket miei_ticket commenta aiuto]
  end

  desc "Registra il webhook del bot Telegram (TELEGRAM_BOT_TOKEN/TELEGRAM_WEBHOOK_SECRET + APP_BASE_URL/MAIL_HOST)"
  task set_webhook: :environment do
    secret = Settings::Integrations.value(:telegram_webhook_secret) || raise(KeyError, "TELEGRAM_WEBHOOK_SECRET")
    base = ENV.fetch("APP_BASE_URL") { "https://#{ENV.fetch('MAIL_HOST')}" }
    # Path FISSO senza segreto (l'URL finisce nei log di Telegram): il gate è l'header secret_token,
    # che il controller valida via X-Telegram-Bot-Api-Secret-Token.
    webhook_url = "#{base}/telegram/webhook"

    puts "→ setWebhook #{webhook_url}"
    puts telegram_api("setWebhook", url: webhook_url, secret_token: secret, drop_pending_updates: "true")
  end

  desc "Rimuove il webhook del bot Telegram"
  task delete_webhook: :environment do
    puts telegram_api("deleteWebhook", drop_pending_updates: "true")
  end

  desc "Registra il menu comandi del bot (setMyCommands) per ogni lingua supportata dall'app"
  task set_commands: :environment do
    # SOLO i locale realmente supportati (App::Constants::LOCALES = en/it), NON I18n.available_locales:
    # in dev/test quest'ultimo è inquinato dai locale di Faker (decine di lingue) e con i fallback
    # ognuna "risolverebbe" telegram.menu.* via en → decine di setMyCommands spuri per lingue fittizie.
    App::Constants::LOCALES.each do |locale|
      commands = menu_command_names.map do |name|
        { command: name, description: I18n.t("telegram.menu.#{name}", locale: locale) }
      end
      payload = { commands: commands }
      # La lingua di default dell'app è il menu universale (nessun language_code); le altre lingue
      # ottengono la propria lista via language_code (Telegram la mostra agli utenti con quella lingua).
      payload[:language_code] = locale unless locale == I18n.default_locale.to_s

      puts "→ setMyCommands (#{locale})"
      puts telegram_api_json("setMyCommands", payload)
    end
  end
end
