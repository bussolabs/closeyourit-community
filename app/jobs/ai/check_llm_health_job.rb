# frozen_string_literal: true

module Ai
  # Controllo periodico (recurring.yml, ogni 15 minuti) che il server AI risponda davvero.
  #
  # Perché serve (CYRA-712): assistente, smistamento automatico, bozze dei ticket e riconoscimento
  # dei doppioni degradano IN SILENZIO quando il fornitore non risponde — una riga di log e basta,
  # e chi guarda le schermate non vede niente. È lo stesso guasto già sorvegliato sugli embedding
  # (Embeddings::CheckServiceHealthJob); questo è il gemello per l'altra metà dell'AI.
  #
  # Perché una generazione VERA e non un `/models` (CYRA-765): con Gemini si provava la chiave di
  # ogni organizzazione con l'elenco dei modelli, che non costava niente. Ora la chiave è una e il
  # server è di casa: vLLM può essere giù dietro LiteLLM, e un `/models` verde lo direbbe sano
  # mentre ogni funzione generativa è ferma. La prova passa dallo STESSO client e dallo stesso alias
  # delle feature, con un tetto di token minimo.
  class CheckLlmHealthJob < ApplicationJob
    queue_as :maintenance

    EVENT_DOWN = "ai_unavailable"
    EVENT_UP = "ai_available"
    DOWN_KEY = "ai:llm_health:down"
    # Chiave o base URL assenti: guasto di configurazione, non di rete. Codice a parte per non
    # mandare in giro un R503 che manderebbe a guardare il server invece del vault.
    UNCONFIGURED_CODE = "R502-LLM-002"
    PROBE = {
      system: "Rispondi con la sola parola: pong",
      contents: [ { role: "user", parts: [ { text: "ping" } ] } ]
    }.freeze

    def perform
      # Con tutte le funzioni generative spente dal god non c'è niente da sorvegliare: la porta è
      # chiusa di proposito, e avvisare per una funzione disattivata è il modo più rapido per far
      # ignorare gli avvisi veri.
      return if Ai::Feature.generative_disabled?

      code = probe
      was_down = Rails.cache.read(DOWN_KEY) == true

      if code
        Rails.logger.error("[Ai::CheckLlmHealthJob] il server AI non risponde (#{code}) — assistente, " \
                           "smistamento, bozze e doppioni stanno degradando in silenzio")
        Rails.cache.write(DOWN_KEY, true, expires_in: 1.day)
        notify(EVENT_DOWN, code)
      elsif was_down
        # Il ricordo si cancella PRIMA dell'avviso di rientro: se la coda è giù il rientro si perde,
        # ma un secondo rientro spurio al giro dopo sarebbe peggio del silenzio.
        Rails.cache.delete(DOWN_KEY)
        notify(EVENT_UP, nil)
      end
    end

    private

    # nil = risponde; altrimenti il codice del guasto.
    def probe
      Ai::Llm::Client.new.generate_content(**PROBE, max_output_tokens: 8)
      nil
    rescue Ai::Llm::Client::Error => e
      e.code
    rescue KeyError
      UNCONFIGURED_CODE
    end

    # A platform alert: it reaches only the gods (CYRA-875).
    def notify(event_type, value) = Alerting::PlatformAlert.notify(event_type: event_type, value: value)
  end
end
