# frozen_string_literal: true

module Member
  # COSA HA CONCLUSO la macchina, reso per fase: ogni fase conclude cose diverse, e mostrarle tutte
  # come un blocco di dati grezzi sarebbe di nuovo «il dato c'è ma non si legge». Accesso difensivo su
  # ogni livello: il payload è dato esterno e la scheda non deve mai esplodere (CYRA-742).
  module AutomationConsiderationsHelper
    # Le considerazioni della macchina, rese per fase: ogni fase conclude cose diverse, e mostrarle
    # tutte come un blob jsonb sarebbe di nuovo "il dato c'è ma non si legge".
    # Ritorna { text:, chips: [], counts: { label => valore } } — tutte le parti sono opzionali.
    def automation_considerations(attempt)
      # Un guasto tecnico (CYRA-282) non consegna un `result` strutturato: il suo contenuto è il MOTIVO
      # del fallimento riportato dalla macchina. Va letto prima del ramo per fase, che si aspetta il
      # result del contratto e uscirebbe a vuoto (result blank → nessun testo).
      return failure_considerations(attempt) if attempt.status_failed?

      result = attempt.result.presence
      # Un tentativo interrotto non ha consegnato niente: senza questa uscita il planner mostrerebbe
      # "scenari 0 · definizione di fatto 0", che si legge come "ha prodotto un piano vuoto" invece che
      # "non è mai arrivato a produrne uno".
      return { text: nil, chips: [], counts: {} } if result.blank?

      case attempt.phase
      when "triage" then triage_considerations(result)
      when "planner" then planner_considerations(result)
      when "autopilot" then autopilot_considerations(result)
      else closer_considerations(result)
      end
    end

    private
    # Il motivo del guasto riportato dalla macchina (CYRA-282). Un fallback quando manca: `failed` senza
    # motivo non dovrebbe mai arrivare (il canale lo pretende), ma i record storici e un payload monco non
    # devono lasciare il passo muto — "è finito con un guasto" è già informazione.
    def failure_considerations(attempt)
      { text: attempt.failure_reason.presence || t("member.tickets.automation.steps.failure_no_reason"),
        chips: [], counts: {} }
    end

    def triage_considerations(result)
      chips = [ result["category"], result["risk"], automation_state_label(result["state"]) ].compact_blank
      chips << t("member.tickets.automation.steps.human_approval") if result["requires_human_approval"]
      { text: Array(result["reasons"]).compact_blank.join(" · ").presence, chips:,
        counts: capability_counts(result) }
    end

    def capability_counts(result)
      capabilities = Array(result["capabilities"]).compact_blank
      return {} if capabilities.empty?

      { t("member.tickets.automation.steps.capabilities") => capabilities.join(", ") }
    end

    def planner_considerations(result)
      # CYRA-675 — quando l'esito è «già fatto» non c'è nessun piano da contare: scenari e criteri
      # sarebbero zero, e la scheda direbbe «ha prodotto un piano vuoto» proprio dove la macchina ha
      # invece consegnato la cosa più importante — dove il lavoro è già scritto. Ramo suo, con il
      # riassunto per esteso e il numero di riferimenti al codice che lo provano.
      return already_done_considerations(result) if result["state"] == "already-done"

      counts = {
        t("member.tickets.automation.steps.scenarios") => Array(result["scenarios"]).size,
        t("member.tickets.automation.steps.definition_of_done") => Array(result["definition_of_done"]).size
      }
      notes = Array(result["notes"]).size
      counts[t("member.tickets.automation.steps.notes")] = notes if notes.positive?
      { text: result.dig("plan", "summary").presence || result["technical_analysis"].presence,
        chips: [], counts: }
    end

    def already_done_considerations(result)
      sources = Array(result.dig("already_done", "sources"))
      { text: result.dig("already_done", "summary").presence,
        chips: [ automation_state_label("already-done") ].compact_blank,
        counts: { t("member.tickets.automation.steps.already_done_sources") => sources.size } }
    end

    def autopilot_considerations(result)
      chips = [ automation_state_label(result["state"]), automation_state_label(result.dig("review", "verdict")) ].compact_blank
      chips << t("member.tickets.automation.steps.gate_passed") if result.dig("gate", "passed")
      counts = {}
      cycles = result["cycles"]
      counts[t("member.tickets.automation.steps.cycles")] = cycles if cycles.present?
      { text: result.dig("failure", "summary").presence || result["reason"].presence, chips:, counts: }
    end

    def closer_considerations(result)
      chips = [ automation_state_label(result["state"]), result["tag"] ].compact_blank
      # CYRA-606 — accanto al numero di versione, la sigla del codice su cui il tag è stato messo.
      # «Rilasciato v1.4.0» da solo non dice su cosa: fra l'approvazione e il rilascio possono
      # passare ore e il codice può cambiare. Accorciata a sette caratteri come fa git: la sigla
      # intera è nel risultato per chi deve confrontarla, qui serve a riconoscerla.
      #
      # Difensiva: il payload è dato esterno e la scheda non deve esplodere per una consegna
      # malfatta. Un closer che si è FERMATO non porta nessun commit, ed è giusto così.
      commit = result["commit"]
      chips << commit.to_s.first(7) if commit.is_a?(String) && commit.present?
      { text: result["reason"].presence, chips:, counts: {} }
    end
  end
end
