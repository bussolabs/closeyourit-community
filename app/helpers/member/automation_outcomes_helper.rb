# frozen_string_literal: true

module Member
  # COM'È ANDATO un passo della tab Automazione e come si chiama quello che si legge: l'esito del
  # tentativo, le parole delle fasi, le sigle del payload con la frase che le spiega. Un solo
  # vocabolario per tutta l'app — due mappe divergerebbero al primo stato nuovo (CYRA-742).
  module AutomationOutcomesHelper
    # Esito → [chiave i18n, colore badge, icona]. `stale`/`cancelled` sono la stessa storia per chi
    # legge ("è finita senza consegnare"), e restano grigi: non sono un verdetto, sono un'interruzione.
    ATTEMPT_OUTCOMES = {
      "approved" => %w[approved green check],
      "review_failed" => %w[rejected red x],
      "rejected" => %w[rejected red x],
      "failed" => %w[failed red triangle-alert],
      "stale" => %w[interrupted gray ban],
      "cancelled" => %w[interrupted gray ban],
      "running" => %w[running indigo loader-circle],
      "awaiting_review" => %w[awaiting_review amber hourglass],
      "blocked" => %w[blocked amber triangle-alert]
    }.freeze

    def automation_outcome(attempt) = automation_outcome_for(automation_outcome_key(attempt))

    # CYRA-876 — a delivered `blocked` result is stored as an `approved` attempt (the delivery was
    # accepted), yet the work did not pass: the host may even have discarded it. Read it as blocked.
    def automation_outcome_key(attempt)
      result = attempt.result
      return "blocked" if attempt.status.to_s == "approved" && result.is_a?(Hash) && result["state"] == "blocked"

      attempt.status.to_s
    end

    # CYRA-602 — la parola che leggi, presa dal vocabolario unico. Le sedici fasi interne diventano
    # otto parole, le stesse su ogni pagina e nelle due lingue.
    #
    # Via il ripiego su `humanize`: stampava il nome interno del passaggio — una parola inglese
    # scritta come la scrivono i programmatori — su una pagina italiana, e siccome era considerato
    # normale, una fase nuova poteva arrivare sotto gli occhi di chi legge senza che nessuno si
    # accorgesse che non le era stato dato un nome. Ora una fase senza parola solleva in sviluppo,
    # e la porta resta chiusa da sé.
    def automation_phase_label(phase)
      t("member.tickets.automation.stage.#{::Agents::Workflows::PhaseResolver.stage(phase)}")
    end

    # La frase che spiega la fase (CYRA-384). Nessun humanize di scorta: una fase nuova senza
    # spiegazione resta senza frase, invece di ricevere il proprio nome ripetuto come se lo fosse.
    def automation_phase_hint(phase)
      t("member.tickets.automation.phase_hint.#{phase}", default: nil)
    end

    def automation_execution_phase_label(phase)
      t("member.tickets.automation.execution_phase.#{phase}", default: phase.to_s.humanize)
    end

    # Le sigle che il passo mostra, ciascuna con la frase che la spiega (CYRA-384): l'esito del
    # tentativo e gli stati del payload. Tradotte lo erano già (CYRA-392) — «bloccato» però non dice
    # né cosa è successo né se riparte da sé, ed è la parola su cui si decide se intervenire.
    #
    # Solo le sigle che una spiegazione ce l'hanno davvero: un valore fuori vocabolario non entra
    # nell'elenco, invece di comparirci accanto a una riga vuota.
    def automation_glossary(attempt)
      outcome = automation_outcome(attempt)
      entries = [ ({ term: outcome[:label], hint: outcome[:hint] } if outcome[:hint].present?) ]
      entries += automation_state_values(attempt).filter_map do |value|
        hint = automation_state_hint(value)
        { term: automation_state_label(value), hint: } if hint.present?
      end
      entries.compact.uniq
    end

    # Stesso verdetto a partire dal solo status: lo storico dell'host (CYRA-279) ha l'esito
    # dell'ultimo tentativo come stringa aggregata, non l'oggetto. Un solo vocabolario per
    # "com'è finito un tentativo" in tutta l'app — due mappe divergerebbero al primo stato nuovo.
    def automation_outcome_for(status)
      key, color, icon = ATTEMPT_OUTCOMES.fetch(status.to_s, %w[running gray circle])
      { label: t("member.tickets.automation.steps.outcome.#{key}"), color: color.to_sym, icon:,
        # CYRA-384 — la frase che spiega l'esito: «interrotto» e «fallito» sono due cose diverse, e la
        # differenza decide se c'è qualcosa da sistemare o solo da riprovare.
        plural: t("member.tickets.automation.steps.outcome_plural.#{key}"),
        hint: t("member.tickets.automation.steps.outcome_hint.#{key}", default: nil) }
    end

    private
    # Gli stati che il passo mostra come chip, letti dal payload consegnato: `state` per ogni fase, più
    # il verdetto della revisione incrociata dell'autopilot. Dato esterno, quindi accesso difensivo su
    # ogni livello — questo gira su OGNI passo, non solo su quelli che il contratto ha validato.
    def automation_state_values(attempt)
      result = attempt.result
      return [] unless result.is_a?(Hash)

      review = result["review"]
      [ result["state"], (review["verdict"] if review.is_a?(Hash)) ].compact_blank
    end

    def automation_state_hint(value)
      return nil if value.blank?

      t("member.tickets.automation.steps.state_hint.#{value.to_s.tr('-', '_')}", default: nil)
    end

    # Etichetta italiana per lo `state`/`verdict` del payload agente (contratto agent-result) mostrato
    # come chip (CYRA-392): valori inglesi (workable/blocked/unavailable/…) che stonavano accanto agli
    # esiti già tradotti. I trattini del contratto (needs-clarification) diventano underscore nella
    # chiave; un valore fuori vocabolario ricade su humanize — il payload è dato esterno, mai crashare.
    def automation_state_label(value)
      return value if value.blank?

      key = value.to_s.tr("-", "_")
      t("member.tickets.automation.steps.state.#{key}", default: key.humanize)
    end
  end
end
