# frozen_string_literal: true

module Vulnerabilities
  # CYRA-1144 — le vulnerabilità ignorate la cui scadenza è arrivata tornano aperte, e per ognuna
  # parte un avviso (gemello di NotifyFindings: stesso giro su Alerting::EvaluateJob, stesso subject).
  #
  # Separato dalla scansione di proposito: un progetto che non si scansiona più (repository scollegato,
  # sincronizzazione spenta) deve comunque vedersi tornare aperte le decisioni scadute.
  #
  # La riapertura automatica conserva motivo, scadenza e autore come memoria di cosa era stato deciso;
  # è riaprire A MANO (Finding#reopen!) che annulla la decisione e li svuota. L'avviso però non li
  # rilegge dalla riga: si compone più tardi sulla coda degli avvisi, e nel frattempo qualcuno può
  # averla ignorata di nuovo o riaperta a mano. Viaggia con una fotografia della decisione scaduta.
  # Le voci ignorate senza scadenza (prima di CYRA-1144) non sono toccate.
  class ReopenExpiredIgnores < ApplicationService
    def initialize(today: Date.current)
      @today = today
    end

    def call
      reopened = 0
      Vulnerabilities::Finding.ignore_expired(@today).find_each do |finding|
        reopened += 1 if reopen(finding)
      end

      Result.ok(reopened)
    end

    private

    # Riapertura e avviso stanno o cadono insieme. L'avviso va su un altro database (la coda) e non
    # entra nella transazione: si accoda DENTRO, dopo l'aggiornamento, così se la coda rifiuta (con
    # un'eccezione o restituendo false) la riga torna ignorata e il giro successivo (o il retry del
    # job) ci riprova, invece di riaprirla in silenzio. La riga si rilegge col lock e solo se è ancora
    # scaduta: se nel frattempo qualcuno l'ha riaperta o ha spostato la scadenza non la tocca e non
    # avvisa, e due giri sovrapposti non avvisano due volte.
    def reopen(finding)
      Vulnerabilities::Finding.transaction do
        current = Vulnerabilities::Finding.ignore_expired(@today).lock.find_by(id: finding.id)
        next false if current.nil?

        decision = decision_of(current)
        current.update_columns(status: Vulnerabilities::Finding.statuses[:open], updated_at: Time.current)
        enqueue_alert(current, decision)
        true
      end
    end

    # Chi, fino a quando, perché: letti dalla riga bloccata, prima che torni aperta.
    def decision_of(finding)
      { "reason" => finding.triage_note, "author" => finding.ignored_by&.name,
        "until" => finding.ignored_until&.iso8601 }
    end

    def enqueue_alert(finding, decision)
      enqueued = Alerting::EvaluateJob.perform_later(
        event_type: "vulnerability_ignore_expired",
        subject_type: "Vulnerabilities::Finding",
        subject_id: finding.id,
        project_id: finding.project_id,
        environment_id: nil,
        decision: decision
      )
      return if enqueued

      raise ActiveJob::EnqueueError, "avviso di scadenza non accodato per la vulnerabilità #{finding.id}"
    end
  end
end
