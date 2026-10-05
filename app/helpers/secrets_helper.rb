# frozen_string_literal: true

module SecretsHelper
  SECRET_EVENT_ICONS = {
    "read" => "eye",
    "set" => "pen",
    "deleted" => "trash",
    "imported" => "file-input",
    "synced" => "refresh-cw",
    # CYRA-78: il tentativo fermato dal confine ambienti — nella lista deve saltare all'occhio che
    # non è un'operazione riuscita come le altre.
    "denied" => "ban",
    # CYRA-79: valore personale assegnato/tolto a una persona. Icona diversa da "set": non è cambiato
    # il segreto del progetto, è cambiato per QUALCUNO.
    "override_set" => "user-pen",
    "override_deleted" => "user-minus",
    # CYRA-777: il valore si è spostato nell'organizzazione. Il progetto lo riceve ancora — l'icona
    # dice "unito ad altri", non "buttato".
    "consolidated" => "group"
  }.freeze

  def secret_event_icon(action) = SECRET_EVENT_ICONS.fetch(action, "circle")

  # CYRA-426: un vocabolario solo per i verbi degli eventi sui secret. Le tre liste di attività e il
  # registro centrale leggono da qui, così la stessa azione si chiama sempre allo stesso modo; le
  # azioni senza voce ricadono su una parola generica, mai sul nome inglese dell'azione.
  def secret_action_label(action)
    t("member.secrets.actions.#{action}", default: t("member.secrets.actions.unknown"))
  end

  # Cella «Secret» del registro: una lettura dell'ambiente intero non ha nome, ma sa quanti ne ha dati.
  def secret_audit_name(row)
    return row.name if row.name.present?

    count = row.metadata.to_h["count"]
    count ? t("member.vault_audit.whole_environment", count: count) : "—"
  end

  # F173 — the detail an audit row carries beyond its columns: where it came from (the command
  # line, the app) and which version it left. nil when the event has nothing more to say.
  def secret_audit_detail(row)
    metadata = row.metadata.to_h
    parts = []
    parts << t("member.vault_audit.detail.channel_#{row.channel}") if %w[web cli].include?(row.channel)
    if metadata["from"] && metadata["to"]
      parts << t("member.vault_audit.detail.version_change", from: metadata["from"], to: metadata["to"])
    elsif metadata["version"]
      parts << t("member.vault_audit.detail.version", version: metadata["version"])
    end
    other_name = metadata["local_name"] || metadata["shared_name"]
    parts << t("member.vault_audit.detail.as_name", name: other_name) if other_name.present?
    parts.join(" · ").presence
  end

  # Frase dell'evento nelle liste. Se l'azione non ha una frase dedicata resta il verbo del
  # vocabolario: nessuna lista può più mostrare il testo di errore delle traduzioni.
  def secret_event_sentence(event, scope: "member.secrets.activity")
    metadata = event.try(:metadata).to_h
    t("#{scope}.#{event.action}",
      name: event.name, count: metadata["count"].to_i,
      default: secret_action_label(event.action))
  end

  # Identical events in a row (same sentence, place and person) read as one line: [[event, count], ...].
  def fold_secret_events(events)
    events.chunk_while { |a, b| secret_event_fold_key(a) == secret_event_fold_key(b) }.map { |run| [ run.first, run.size ] }
  end

  def folded_secret_event_sentence(event, count)
    return secret_event_sentence(event) if count == 1
    return t("member.secrets.activity_read_times", count: count) if event.action == "read"

    t("member.secrets.activity_times", sentence: secret_event_sentence(event), count: count)
  end

  def secret_event_fold_key(event)
    [ event.action, event.name, event.actor_id, event.environment_id, event.metadata.to_h["count"] ]
  end

  # Tempo relativo in italiano, con data e ora esatte al passaggio del mouse.
  def secret_event_time(time)
    return if time.blank?

    tag.span(t("member.secrets.updated_ago", time: time_ago_in_words(time)), title: l(time, format: :long))
  end

  # CYRA-106 — perché l'ultimo invio dei secret verso GitHub non è riuscito, detto a chi legge la
  # scheda del progetto. La spiegazione arriva dal CODICE dell'errore, non dal suo messaggio: i codici
  # sono nostri e traducibili, mentre il messaggio di un guasto di trasporto è testo che scrive
  # GitHub. Resta il fallback al messaggio registrato per i codici che non abbiamo previsto: meglio
  # una frase inglese di un errore muto.
  def secret_sync_failure_reason(repository)
    code = repository.last_sync_error_code
    fallback = repository.last_sync_error_message.presence || t("member.project_github.last_sync_unknown_reason")
    return fallback if code.blank?

    t("member.project_github.sync_errors.#{code}", default: fallback)
  end

  # I fatti registrati con l'errore: quale slot GitHub si è fermato, quale file e riga lo blocca,
  # quali nomi mancano. Sono nomi, percorsi e numeri di riga — mai valori (vedi Secrets::Github::SyncJob).
  def secret_sync_failure_facts(repository)
    details = repository.last_sync_error_details
    scope = "member.project_github"
    facts = []
    facts << t("#{scope}.last_sync_fact_slot", slot: repository.last_sync_error_slot) if repository.last_sync_error_slot.present?
    facts << secret_sync_failure_source(details, scope) if details["path"].present?
    facts << t("#{scope}.last_sync_fact_missing", names: Array(details["missing"]).join(", ")) if details["missing"].present?
    facts << t("#{scope}.last_sync_fact_unset", names: Array(details["unset"]).join(", ")) if details["unset"].present?
    # CYRA-637 — senza questa riga la scheda direbbe che la sincronizzazione si è fermata, ma non
    # quale ambiente collegare: la correzione resterebbe da indovinare.
    facts << t("#{scope}.last_sync_fact_unmapped", names: Array(details["unmapped"]).join(", ")) if details["unmapped"].present?
    # CYRA-652 — quali file non si sono letti: senza, la scheda dice che il bundle manca ma non dove
    # andare a guardare.
    facts << t("#{scope}.last_sync_fact_unreadable", names: Array(details["unreadable"]).join(", ")) if details["unreadable"].present?
    facts
  end

  private

  def secret_sync_failure_source(details, scope)
    return t("#{scope}.last_sync_fact_file", path: details["path"]) if details["line"].blank?

    t("#{scope}.last_sync_fact_line", path: details["path"], line: details["line"])
  end
end
