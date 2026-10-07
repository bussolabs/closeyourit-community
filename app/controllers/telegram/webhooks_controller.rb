# frozen_string_literal: true

module Telegram
  # Webhook inbound del bot ufficiale (canale Telegram::, rules/backend-channels.md). Machine POST JSON:
  # eredita da ActionController::API (niente CSRF né allow_browser, che scarterebbero la richiesta di
  # Telegram). Nessuna auth utente — il gate è l'header X-Telegram-Bot-Api-Secret-Token (== ENV
  # TELEGRAM_WEBHOOK_SECRET, impostato via `secret_token` su setWebhook). Gli header NON finiscono nei
  # log Rails (il path sì) → nessun segreto loggato. Risponde SEMPRE 200 sugli update validi (anche
  # ignorati) per non innescare i retry di Telegram; header errato/assente → 404 (nasconde l'endpoint).
  class WebhooksController < ActionController::API
    SECRET_HEADER = "X-Telegram-Bot-Api-Secret-Token"

    # I soli campi che i comandi leggono davvero (Telegram::HandleUpdate + Respondable#telegram_media):
    # chat e mittente, testo o didascalia, foto o documento. Tutto il resto dell'update — che Telegram
    # può allargare quando vuole — non entra nell'applicazione (CYRA-720).
    UPDATE_SCHEMA = [
      { message: [ :text, :caption,
                   { chat: [ :id, :username, :type, :title, :is_forum ] },
                   { from: [ :username ] },
                   { photo: [ :file_id ] },
                   { document: [ :file_id, :file_name ] } ] },
      # A tap on a Puck's Confirm/Discard button (CYRA-1018).
      { callback_query: [ :id, :data, { message: [ { chat: [ :id ] } ] } ] }
    ].freeze

    # Campi che i comandi leggono con `dig`: devono essere OGGETTI. Il filtro qui sopra controlla i
    # NOMI, non la forma — `permit(chat: [:id])` accetta anche una LISTA di oggetti al posto
    # dell'oggetto, e quella lista arriverebbe intera ai comandi facendo sollevare `dig` esattamente
    # come prima del filtro. Quindi dopo il filtro si controlla anche la forma.
    OBJECT_FIELDS = %w[chat from document].freeze

    before_action :verify_secret

    # Un corpo illeggibile non è un update: si lascia cadere rispondendo 200, come per gli update
    # ignorati. Un non-2xx farebbe ritentare Telegram su una consegna che non migliorerà.
    rescue_from ActionDispatch::Http::Parameters::ParseError do
      Rails.logger.warn("[telegram.webhook] corpo non leggibile: consegna ignorata")
      head :ok
    end

    def create
      # HandleUpdate legge solo update[:message]. head :ok anche sugli update ignorati/invalidi.
      Telegram::HandleUpdate.call(update: update_params)
      head :ok
    end

    private

    def update_params
      permitted = params.permit(*UPDATE_SCHEMA).to_h
      callback = permitted["callback_query"]
      return { "callback_query" => callback } if callback.is_a?(Hash) && callback["message"].is_a?(Hash) && callback.dig("message", "chat").is_a?(Hash)

      message = permitted["message"]
      return {} unless message.is_a?(Hash)

      { "message" => normalized_message(message) }
    end

    # Scarta i campi che non hanno la forma che i comandi si aspettano: gli oggetti che arrivano come
    # liste (o viceversa) valgono come assenti. La lista delle foto tiene solo gli elementi che sono
    # davvero un file.
    def normalized_message(message)
      message.each_with_object({}) do |(field, value), normalized|
        case field
        when *OBJECT_FIELDS then normalized[field] = value if value.is_a?(Hash)
        when "photo" then normalized[field] = value.grep(Hash) if value.is_a?(Array)
        else normalized[field] = value
        end
      end
    end

    def verify_secret
      expected = Settings::Integrations.value(:telegram_webhook_secret).to_s
      given = request.headers[SECRET_HEADER].to_s
      return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)

      head :not_found
    end
  end
end
