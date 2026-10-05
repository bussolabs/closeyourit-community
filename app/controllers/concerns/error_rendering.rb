# frozen_string_literal: true

# Rende gli errori come envelope JSON `{ error: { code, message, details? } }` (rules/rails/api.md).
module ErrorRendering
  extend ActiveSupport::Concern

  included do
    # Risorsa non trovata (anche anti-BOLA: id di un'altra org/progetto → find solleva qui).
    rescue_from ActiveRecord::RecordNotFound do
      render_error("R404-SYSTEM-001", "Risorsa non trovata", status: :not_found)
    end

    # CYRA-718 — le tre eccezioni che il framework solleva PRIMA che il codice di dominio possa dire
    # la sua. Senza una resa qui finivano su `config.exceptions_app`, cioè su ErrorsController, che
    # rende una PAGINA HTML: un canale macchina riceveva del markup (o un 500, perché quella pagina
    # tocca a sua volta i parametri illeggibili) al posto dell'envelope. Stanno nella base comune e
    # non nei singoli controller proprio perché il formato deve essere lo stesso su tutti i canali;
    # un `rescue_from` più specifico registrato nel figlio continua ad avere la precedenza — è così
    # che l'ingest conserva i suoi codici di dominio (R422-LOG-001, R422-INGEST-001, …).
    # `details` = `errors.to_hash`, campo → messaggi: è la forma che i controller usano già quando
    # gestiscono la validazione sul posto (`details: record.errors.to_hash`). Una forma diversa qui
    # obbligherebbe chi legge la risposta a sapere PRIMA quale dei due percorsi l'ha prodotta.
    rescue_from ActiveRecord::RecordInvalid do |exception|
      errors = exception.record&.errors
      render_error("R422-SYSTEM-001", errors&.full_messages.to_a.to_sentence.presence || "Validazione fallita",
                   status: :unprocessable_content, details: errors&.to_hash || {})
    end

    rescue_from ActionController::ParameterMissing do |exception|
      render_error("R422-SYSTEM-002", "Parametro mancante", status: :unprocessable_content,
                   details: { param: exception.param.to_s })
    end

    # Il corpo non è JSON valido: nessun parametro è leggibile, quindi non c'è nulla da validare.
    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render_error("R400-SYSTEM-001", "Corpo della richiesta non leggibile", status: :bad_request)
    end
  end

  private

  def render_error(code, message, status:, details: nil)
    error = { code:, message: }
    error[:details] = details if details
    render json: { error: }, status: status
  end
end
