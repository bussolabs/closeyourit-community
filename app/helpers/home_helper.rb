# frozen_string_literal: true

module HomeHelper
  # Suffisso i18n dei pulsanti di decisione (CYRA-262). Per un'analisi dell'automa il verbo giusto
  # dipende dalla FASE — approvare un piano, approvare il lavoro consegnato e sbloccare una review
  # ferma sono tre decisioni diverse, e chiamarle tutte "Approva" mentirebbe su cosa succede dopo.
  # Per le altre famiglie basta il tipo.
  def approval_variant(card)
    card.kind == "agent_plan" ? card.phase : card.kind
  end

  # CYRA-591 — la striscia dei passaggi in cima alla scheda: dice sempre a che punto della catena si
  # sta decidendo. Aprendo una scheda da un link, senza, non si capisce.
  #
  # La sequenza e gli stati NON si ricalcolano qui: li dà `Agents::RunTimeline`, che è già l'autorità
  # per la pagina host e legge `PhaseProfile::PHASES`. Riscrivere l'elenco significherebbe che una
  # fase nuova comparirebbe là e non qui — con la variante peggiore che i due elenchi divergano in
  # silenzio. Questa striscia aggiunge una cosa sola: lo stato `failed`, che alla pagina host non
  # serve perché non decide niente.
  #
  # → [{ phase:, state: }] con state fra done, current, failed, pending. `nil` quando dietro non c'è
  # una lavorazione automatica: una richiesta sui segreti non ha una catena da mostrare.
  # CYRA-619 — la striscia della scheda mostra gli STESSI sei passaggi della griglia: due schermate
  # della stessa riga non possono dire due cose diverse. Prima raccontava la catena con le cinque fasi
  # interne della macchina, cioè con parole ancora diverse da quelle della plancia e da quelle del
  # ticket — tre vocabolari per la stessa lavorazione.
  def approval_pipeline(card)
    workflow = card.workflow
    return nil if workflow.blank?

    stopped_step = Agents::Workflows::PhaseResolver.step_of_execution_phase(approval_failed_phase(card, workflow))
    current_step = approval_current_step(approval_phase_of(card, workflow))
    index = Agents::Workflows::PhaseResolver::STEPS.index(current_step)

    Agents::Workflows::PhaseResolver::STEPS.each_with_index.map do |step, position|
      { phase: step, state: approval_step_state(step, position, index, stopped_step) }
    end
  end

  # Il passaggio in cui la lavorazione si trova. Su una ferma o annullata il passaggio è un'USCITA
  # (`blocked`, `cancelled`), che nelle sei tappe non c'è: nessun «sei qui» cade da sé, senza una
  # guardia apposta — dipingere «sei qui» su una lavorazione che non gira è dichiararla viva mentre
  # il corpo appena sotto dice il contrario.
  def approval_current_step(phase)
    return nil if phase.blank?

    Agents::Workflows::PhaseResolver.stage(phase)
  end

  def approval_step_state(step, position, index, stopped_step)
    return "failed" if step == stopped_step
    return "pending" if index.nil?
    return "done" if position < index
    return "current" if position == index

    "pending"
  end

  # La fase su cui una revisione ha fermato la lavorazione.
  #
  # `blocked_phase` è la COLONNA che il dominio scrive quando i tentativi si esauriscono: è
  # l'autorità. L'ultimo tentativo respinto da solo non basta, e mente in due modi opposti — se
  # l'host muore gli attempt restano `stale` e nessuno risulta respinto (nessun segno rosso su una
  # lavorazione morta), e una bocciatura vecchia di una fase poi superata segnerebbe respinto un
  # passaggio che invece è stato approvato.
  def approval_failed_phase(card, workflow)
    return nil unless approval_phase_of(card, workflow) == "review_blocked"

    workflow.blocked_phase.presence || card.attempt&.phase
  end

  # Le card `review` e `clarification` nascono senza fase: lì l'autorità è il workflow.
  def approval_phase_of(card, workflow) = card.phase.presence || workflow.phase

  # L'indirizzo della scheda a tutta pagina. Il formato della chiave lo conosce `Card#id`, non la view.
  def approval_item_path(card)
    member_home_approvals_item_path(kind: card.kind, id: card.id)
  end
  # CYRA-324 — nelle card la data relativa serve finché è recente: «3 ore fa» si legge al volo,
  # «11 giorni fa» costringe comunque a fare il conto. Oltre la soglia si passa alla forma assoluta
  # breve («lun 5 ago»), che a quella distanza è più utile e non invecchia mentre la pagina è aperta.
  # Soglia a 3 giorni: entro il fine settimana il relativo resta l'informazione giusta.
  ABSOLUTE_AFTER = 3.days

  def card_time(time, now: Time.current)
    return nil if time.blank?

    return t("member.home.time_ago", time: time_ago_in_words(time)) if now - time < ABSOLUTE_AFTER

    l(time.to_date, format: :card)
  end

  # CYRA-884 — the queue total split by state, with the same labels as the approvals filters so the
  # number on the home and the one on the filter always match. At most three states; the others are
  # summed into the remainder.
  QUEUE_BREAKDOWN_LIMIT = 3

  # CYRA-886 — what a delivery claims, counted from the agent's work report. Every number is stated by
  # the agent (`reported`), never verified here, and the page says so.
  DeliveryEvidence = Data.define(:criteria_done, :criteria_total, :tests_done, :tests_total, :deviations)

  def delivery_evidence(attempt)
    report = attempt&.result.to_h["work_report"]
    return unless report.is_a?(Hash)

    criteria = Array(report["acceptance_evidence"])
    tests = Array(report["tests"])
    DeliveryEvidence.new(criteria_done: criteria.count { |item| item.to_h["status"] == "verified" },
                         criteria_total: criteria.size,
                         tests_done: tests.count { |item| item.to_h["status"] == "passed" },
                         tests_total: tests.size,
                         deviations: Array(report["deviations"]).map(&:to_h))
  end

  def delivery_decision_card(attempt)
    card = attempt&.result.to_h["decision_card"]
    card if card.is_a?(Hash) && card["headline"].present?
  end

  # CYRA-887 — proposed answers per question, by position, read from the attempt that asked (the
  # ticket keeps only the text). An empty list means a plain question.
  def clarification_options(clarification)
    Array(clarification&.attempt&.result.to_h["questions"]).map do |question|
      question.is_a?(Hash) ? Array(question["options"]).map(&:to_h).first(3) : []
    end
  end

  def queue_breakdown(totals)
    ordered = Home::Approvals::Queue::STATES.filter_map do |state|
      count = totals[state].to_i
      [ state, count ] if count.positive?
    end
    shown = ordered.first(QUEUE_BREAKDOWN_LIMIT).map { |state, count| [ t("member.approvals.filters.#{state}"), count ] }
    [ shown, ordered.drop(QUEUE_BREAKDOWN_LIMIT).sum(&:last) ]
  end
end
