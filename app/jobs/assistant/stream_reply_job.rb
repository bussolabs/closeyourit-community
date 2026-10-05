# frozen_string_literal: true

module Assistant
  # Consuma lo stream del server AI per UNA risposta dell'assistente e lo inoltra al browser via
  # Turbo Stream.
  # Gira sul worker (coda :ai): la chiamata LLM è lunga e NON deve occupare un thread web (Puma ha pochi
  # thread — un SSE sincrono sul web sarebbe un self-DoS).
  #
  # La leg server AI→app è vero SSE token-by-token; la leg app→browser è COALESCED (buffer flushato ogni
  # ~FLUSH_INTERVAL) e appende SOLO il delta, non il testo cumulato: solid_cable è su SQLite (single
  # writer) e un broadcast per token lo martellerebbe. A fine stream il messaggio viene finalizzato
  # (content pieno, status complete) e la bolla intera rimpiazzata col partial definitivo. Ogni errore
  # (provider giù, config mancante, nessun testo) degrada pulito: status failed + error_code, mai un 500.
  class StreamReplyJob < ApplicationJob
    queue_as :ai

    # Un solo streaming per CONVERSAZIONE alla volta (non per singolo messaggio): oltre a proteggere dalla
    # consegna at-least-once di Solid Queue (stesso job due volte), serializza gli invii ravvicinati nella
    # stessa conversazione — che altrimenti girerebbero in parallelo, con risposte intercalate e una
    # history costruita prima che la risposta precedente sia finalizzata. Conversazioni diverse restano
    # parallele. La chiave deriva il conversation_id dal messaggio (fallback al message_id se sparito).
    limits_concurrency to: 1, key: ->(message_id:) {
      Assistant::Message.where(id: message_id).pick(:conversation_id) || message_id
    }

    # Coalescing dei broadcast: accumula i delta e flusha al più ogni 100ms (solid_cable polla a 0.1s).
    FLUSH_INTERVAL = 0.1

    def perform(message_id:)
      message = Assistant::Message.find_by(id: message_id)
      return unless message&.status_streaming?

      # Il job gira FUORI dalla request: va reidratato il contesto utente o il partial finale rende link
      # non cliccabili (l'helper del catalogo legge Current.account/organization) e le stringhe UI nel
      # locale di default. Current è impostato PRIMA di with_locale così vale anche nei rescue (bolla
      # d'errore localizzata) e viene azzerato nell'ensure.
      conversation = message.conversation
      Current.account = conversation.account
      Current.organization = conversation.organization

      I18n.with_locale(conversation.account.effective_locale) do
        stream_reply(message)
      rescue Ai::Llm::Client::Error => e
        # Errore di trasporto/provider (auth, upstream ≥400, rate-limit, timeout, rete). Degrada pulito
        # MA logga la causa reale: senza, il fallimento è invisibile al self-monitoring (resta solo
        # l'error_code sulla riga DB) e non diagnosticabile. warn = degrado gestito, catturato dalla gemma.
        log_provider_error(e)
        fail_message(message, e.code)
      rescue KeyError => e
        # Server AI non configurato (chiave o indirizzo assenti): stesso trattamento di un guasto del
        # fornitore — bolla chiusa, causa a log — ma con un codice che dice che manca la configurazione.
        Rails.logger.error("[Assistant::StreamReplyJob] server AI non configurato: #{e.message}")
        fail_message(message, "R502-LLM-002")
      rescue StandardError => e
        # Qualsiasi altro errore (catalogo, i18n, locale non valido, ecc.) NON deve lasciare il messaggio
        # eternamente in streaming: marca failed e logga. Gestire qui impedisce anche il retry di ActiveJob
        # che ri-eseguirebbe lo stream da capo ri-appendendo il testo già mandato.
        Rails.logger.error("[Assistant::StreamReplyJob] #{e.class}: #{e.message}")
        fail_message(message, "R502-LLM-001")
      end
    ensure
      Current.account = nil
      Current.organization = nil
    end

    private

    # Un server AI senza capacità (R503) è l'unico guasto del fornitore che rende l'assistente muto
    # per TUTTI e resta tale finché non si libera posto: non c'è modello di riserva, il 503 propaga
    # e basta. Va a `error` perché non è l'inciampo di una richiesta ma la funzione ferma, e a `warn`
    # sarebbe indistinguibile dai timeout di passaggio — la prima volta se ne accorse una persona
    # provando la chat dodici volte a mano (CYRA-186).
    def log_provider_error(error)
      text = "[Assistant::StreamReplyJob] server AI #{error.code}: #{error.message}"

      if error.code == Ai::Llm::Client::UNAVAILABLE_CODE
        Rails.logger.error("#{text} — nessun modello disponibile, l'assistente non risponde")
      else
        Rails.logger.warn(text)
      end
    end

    def stream_reply(message)
      # Il client legge la configurazione di sistema (CYRA-765): se manca solleva KeyError, che il
      # perform intercetta e chiude la bolla — NON si può lasciare in "sto scrivendo" per sempre.
      client = Ai::Llm::Client.new

      # Catalogo e prompt nella lingua dell'utente (già entro I18n.with_locale dal perform).
      system = system_prompt(message)
      contents = history(message)

      full = +""
      pending = +""
      last_flush = Time.current

      client.stream_chat(system: system, contents: contents) do |delta|
        full << delta
        pending << delta
        if Time.current - last_flush >= FLUSH_INTERVAL
          append(message, pending)
          pending = +""
          last_flush = Time.current
        end
      end

      append(message, pending) if pending.present?
      finalize(message, full)
    end

    def finalize(message, content)
      # Content vuoto = il server AI ha risposto ma non ha prodotto testo per questa domanda: è una
      # RISPOSTA NON PRODOTTA (R502-LLM-004), non un guasto momentaneo (R502-LLM-001, riservato
      # a rete/upstream/errori inattesi). La bolla d'errore usa questa distinzione (CYRA-436) per dire
      # all'utente se riformulare o riprovare più tardi.
      return fail_message(message, Ai::Llm::Client::NO_TEXT_CODE) if content.blank?

      message.update!(status: :complete, content: content)
      broadcast_replace(message)
    end

    def fail_message(message, code)
      return unless message

      message.update!(status: :failed, error_code: code)
      broadcast_replace(message)
    end

    # Contesto server-side ricostruito dal RESOLVER reale (mai fidarsi del client): il catalogo è quello
    # dell'owner della conversazione, filtrato ai suoi permessi.
    def system_prompt(message)
      conversation = message.conversation
      catalog = Assistant::BuildCatalog.call(account: conversation.account, organization: conversation.organization)
      Assistant::SystemPrompt.call(catalog: catalog)
    end

    def history(message)
      Assistant::BuildHistory.call(conversation: message.conversation, until_message: message)
    end

    # Appende SOLO il delta (escaped) al contenitore body della bolla in streaming.
    def append(message, text)
      Turbo::StreamsChannel.broadcast_append_to(
        stream_for(message),
        target: "#{dom_id(message)}_body",
        html: ERB::Util.html_escape(text)
      )
    end

    # Rimpiazza l'intera bolla col partial definitivo (content completo reso, o bolla d'errore).
    def broadcast_replace(message)
      Turbo::StreamsChannel.broadcast_replace_to(
        stream_for(message),
        target: dom_id(message),
        partial: "member/assistant_conversations/message",
        locals: { message: message }
      )
    end

    def stream_for(message)
      Realtime::Streams.assistant_conversation(message.conversation)
    end

    def dom_id(message)
      ActionView::RecordIdentifier.dom_id(message)
    end
  end
end
