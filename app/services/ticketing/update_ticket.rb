# frozen_string_literal: true

module Ticketing
  # Aggiorna un ticket esistente (già scoped all'org dal controller). Il project NON cambia
  # (la numerazione è per-progetto): si aggiornano titolo, corpo (description/scenari/DoD/analisi
  # tecnica), priority, epic padre e platforms. Stato, responsabile e traguardo sono invece delegati
  # ai service dedicati (ChangeStatus/AssignTicket/ChangeMilestone) perché anche dal modulo di modifica
  # partano evento tipizzato, notifica ai watcher, auto-iscrizione dell'assegnatario e broadcast
  # realtime — gli stessi effetti dei pulsanti rapidi, che il salvataggio dal form non produceva (CYRA-244).
  class UpdateTicket < ApplicationService
    # CYRA-609 — `channel:` obbligatorio come in ChangeStatus, e per la stessa ragione: questa e' la
    # seconda porta da cui uno stato si sposta, e da dove arriva la richiesta decide se puo' farlo.
    def initialize(organization:, ticket:, params:, channel:, actor: nil, true_actor: nil)
      @organization = organization
      @ticket = ticket
      @params = params
      @channel = channel
      @actor = actor
      @true_actor = true_actor
    end

    def call
      return body_locked if body_change_requested? && @ticket.agent_workflow&.body_locked?

      # Snapshot PRIMA dell'assign: per priority/parent servono label/codice di partenza; le platforms
      # (M:N) non compaiono in saved_changes → diff di array. Scenari e DoD sono record a parte →
      # snapshot testuale (via BodyText), che serve sia al diff di cronologia sia al trigger di re-embed.
      before = {
        priority: @ticket.priority,
        parent: @ticket.parent,
        platforms: @ticket.platforms.to_a,
        scenarios: Ticketing::BodyText.scenarios(@ticket.scenarios),
        conditions: Ticketing::BodyText.conditions(@ticket.conditions)
      }
      scenarios_before = before[:scenarios]

      @ticket.assign_attributes(update_attributes)

      # CYRA-788 — UNA transazione per tutto il salvataggio: corpo, evento `updated` e i cambi tipizzati
      # (stato → responsabile → traguardo). Prima corpo ed evento erano già committati quando lo stato o
      # il traguardo dicevano di no, e il ticket restava a metà: titolo nuovo salvato, stato vecchio, e
      # un messaggio d'errore che non corrispondeva a quello che si vedeva. Se un campo viene rifiutato
      # si fa rollback di tutto — nessun campo, nessun evento, nessuna notifica.
      #
      # I job dei service tipizzati sono al sicuro perché registrati con `after_all_transactions_commit`:
      # partono solo se QUESTA transazione committa, e mai su rollback. Quelli di questo service
      # (re-embed, gate agenti) restano fuori dalla transazione, dopo il commit riuscito.
      semantic_changed = false
      typed_change = nil
      ApplicationRecord.transaction do
        @ticket.save!
        log_changes(before)
        # Il test va fatto QUI: i service tipizzati fanno `update!` sullo stesso oggetto e azzererebbero
        # `saved_changes`. Re-embed SOLO se è cambiato il testo semantico (colonne watched OPPURE gli
        # scenari, che sono record a parte e non toccano ticket.saved_changes).
        semantic_changed = (@ticket.saved_changes.keys & Ticketing::EmbeddingText::WATCHED_COLUMNS).any? ||
                           Ticketing::BodyText.scenarios(@ticket.scenarios.reload) != scenarios_before
        # Stato, responsabile e traguardo → service dedicati (CYRA-244): no-op, evento tipizzato,
        # auto-iscrizione dell'assegnatario, NotifyJob ai watcher e broadcast realtime. Un errore di
        # dominio del service (stato con dipendenze aperte, milestone fuori progetto) annulla tutto e
        # risale al chiamante.
        typed_change = apply_typed_changes
        raise ActiveRecord::Rollback if typed_change
      end
      return typed_change if typed_change

      # Fuori transazione, mai after_commit.
      Ticketing::EmbedTicketJob.perform_later(ticket_id: @ticket.id) if semantic_changed
      # Rivalutazione del gate agenti (CYRA-184). La condizione è `stale?` e NON una seconda lista di
      # colonne osservate: quella di EmbeddingText esclude le condizioni DoD e ignora gli allegati,
      # e mantenerne due divergenti a mano sarebbe una fonte di buchi. Il checksum è già la sorgente
      # unica di verità, e su un ticket con decisione umana `stale?` è falso per definizione.
      enqueue_agent_eligibility if @ticket.agent_eligibility_stale?

      Result.ok(@ticket)
    rescue ActiveRecord::RecordInvalid => e
      # Solo l'invalidità del TICKET (o dei suoi nested scenari/condizioni) è un 422 utente; un evento
      # invalido (bug) deve propagare e far rollback della modifica, non mascherarsi da 422.
      raise unless e.record == @ticket || e.record.is_a?(Ticketing::Scenario) || e.record.is_a?(Ticketing::Condition)

      Result.err(AppError.new(@ticket.errors.full_messages.to_sentence,
                              code: "R422-TICKET-002", details: @ticket.errors.to_hash))
    end

    private

    def enqueue_agent_eligibility
      Ticketing::AgentEligibilityQueue.enqueue(ticket: @ticket)
    end

    BODY_FIELDS = %i[title description technical_analysis scenarios_attributes conditions_attributes].freeze

    def body_change_requested?
      scalar_changes = {
        title: @ticket.title,
        description: @ticket.description,
        technical_analysis: @ticket.technical_analysis
      }.any? do |field, current|
        param_given?(field) && normalized(field, @params[field]) != normalized(field, current)
      end
      nested_changes = %i[scenarios_attributes conditions_attributes].any? { |field| param_given?(field) }
      scalar_changes || nested_changes
    end

    # ENTRAMBI i lati normalizzati come farebbe il model, senza duplicarne la logica. I param
    # arrivano grezzi dal browser (le textarea inviano CRLF); il valore corrente arriva dal DB, e
    # anche quello può essere grezzo — Rails normalizza in scrittura, non in lettura, quindi un
    # ticket scritto prima della normalizzazione conserva i suoi \r. Confrontare lunghezze o
    # stringhe disomogenee farebbe sembrare MODIFICATO un corpo rinviato identico → a body bloccato
    # un salvataggio innocuo verrebbe rifiutato con R409.
    def normalized(field, value)
      Ticketing::Ticket.normalize_value_for(field, value).to_s
    end

    def body_locked
      Result.err(
        AppError.new(
          "Il contenuto del ticket è bloccato mentre l'automazione è in corso",
          code: "R409-TICKET-006", status: :conflict
        )
      )
    end

    def update_attributes
      attrs = {
        title: value_or_current(:title, @ticket.title),
        # kind assente → mantieni il corrente (mai nil su colonna null:false).
        kind: (@params[:kind].presence || @ticket.kind),
        description: value_or_current(:description, @ticket.description),
        technical_analysis: value_or_current(:technical_analysis, @ticket.technical_analysis),
        weight: value_or_current(:weight, @ticket.weight)&.presence,
        due_at: value_or_current(:due_at, @ticket.due_at)&.presence,
        priority: relation_value_or_current(:priority_id, @organization.ticket_priorities, @ticket.priority),
        parent: parent,
        platforms: platforms
      }
      # Nested solo se presenti (nil su scenarios_attributes= solleverebbe). REPLACE, non append:
      # il set inviato SOSTITUISCE quello esistente — vedi replace_nested.
      attrs[:scenarios_attributes]  = replace_nested(@ticket.scenarios,  @params[:scenarios_attributes])  if @params[:scenarios_attributes].present?
      attrs[:conditions_attributes] = replace_nested(@ticket.conditions, @params[:conditions_attributes]) if @params[:conditions_attributes].present?
      attrs
    end

    # accepts_nested_attributes tratta una riga senza id come nuovo record → append. Per ottenere il
    # REPLACE (il contratto "full replace" già dichiarato dalla CLI), sintetizziamo _destroy per gli id
    # esistenti assenti dal payload: il web invia gli id (update-by-id, invariato), il CLI non li invia
    # (tutti gli esistenti eliminati + i nuovi creati). Le righe {id, _destroy:true} bypassano il reject_if.
    def replace_nested(existing, incoming)
      # incoming può essere un Array (canale CLI) OPPURE un Hash indicizzato {"0"=>{…},"1"=>{…}}
      # (form web, ActionController::Parameters): normalizziamo alle sole righe prima di iterare —
      # su un Hash `filter_map` itererebbe coppie [k,v] e `row[:id]` esploderebbe (CYRA-171).
      rows = incoming.respond_to?(:values) ? incoming.values : Array(incoming)
      sent_ids = rows.filter_map { |row| (row[:id] || row["id"]).presence }.map(&:to_s)
      destroys = (existing.ids.map(&:to_s) - sent_ids).map { |id| { id: id, _destroy: true } }
      rows + destroys
    end

    # Costruisce il diff prima→dopo dal save e lo registra come UN evento `updated` aggregato
    # (una modifica dal form salva più campi insieme). Label umane, non id: la cronologia resta
    # veritiera anche se una priority viene poi rinominata. Nessun cambio reale → niente evento.
    def log_changes(before)
      diff = {}
      saved = @ticket.saved_changes
      %w[title description weight due_at technical_analysis].each do |column|
        diff[column] = saved[column] if saved.key?(column)
      end
      # kind: per un enum, saved_changes porta già le chiavi umane (["bug", "story"]).
      diff[:kind]     = { from: saved["kind"].first, to: @ticket.kind } if saved.key?("kind")
      # Status/assignee/milestone NON compaiono qui: sono delegati ai service dedicati, che emettono i
      # propri eventi tipizzati (status_changed/assigned/unassigned/milestone_changed). Aggregarli anche
      # in `updated` sarebbe una doppia riga in cronologia (CYRA-244).
      # simplecov:disable priority è un'associazione obbligatoria (priority_id null:false): dopo un save valido è
      # sempre presente, e lo snapshot _before di un ticket persistito pure → l'arm `&.label` con
      # ricevente nil è difesa irraggiungibile via API.
      diff[:priority] = { from: before[:priority]&.label, to: @ticket.priority&.label } if saved.key?("priority_id")
      # simplecov:enable
      # Epic padre: il codice (KEY-N) è l'identità leggibile e stabile, il titolo può cambiare.
      diff[:parent] = { from: before[:parent]&.code, to: @ticket.parent&.code } if saved.key?("parent_id")

      after = @ticket.platforms.reload.to_a
      added = (after - before[:platforms]).map(&:label)
      removed = (before[:platforms] - after).map(&:label)
      diff[:platforms] = { added: added, removed: removed } if added.any? || removed.any?

      # Scenari e DoD: diff testuale (BodyText) — cambia solo se il testo renderizzato differisce.
      scenarios_after = Ticketing::BodyText.scenarios(@ticket.scenarios.reload)
      diff[:scenarios] = { from: before[:scenarios], to: scenarios_after } if scenarios_after != before[:scenarios]
      conditions_after = Ticketing::BodyText.conditions(@ticket.conditions.reload)
      diff[:conditions] = { from: before[:conditions], to: conditions_after } if conditions_after != before[:conditions]

      return if diff.empty?

      RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                          action: "updated", data: diff)
    end

    # Delega stato/responsabile/traguardo ai service dedicati, in ordine; si ferma e ritorna al primo
    # errore di dominio (stato invalido o con dipendenze aperte, milestone fuori progetto). nil = tutti
    # applicati o saltati (nessun campo da toccare). I service gestiscono già no-op, evento tipizzato,
    # auto-iscrizione, NotifyJob e broadcast: qui non si duplica nulla. Gira DENTRO la transazione di
    # `call` (CYRA-788): un errore fa rollback anche dei service già passati.
    def apply_typed_changes
      %i[change_status assign_member change_milestone].each do |service|
        result = send(service)
        return result if result&.err?
      end
      nil
    end

    def change_status
      return if skip_meta?(:status_id)

      # CYRA-609 — questa e' la SECONDA porta: uno status_id dentro una modifica del ticket sposta lo
      # stato esattamente come il comando dedicato. Il canale arriva dal controller e viene inoltrato:
      # dedurlo qui vorrebbe dire indovinare da dove e' arrivata la richiesta.
      Ticketing::ChangeStatus.call(organization: @organization, ticket: @ticket, channel: @channel,
                                   status_id: @params[:status_id], actor: @actor, true_actor: @true_actor)
    end

    # blank → disassegna; id fuori org → resta non assegnato (anti-BOLA gestito dal service).
    def assign_member
      return if skip_meta?(:assignee_id)

      Ticketing::AssignTicket.call(organization: @organization, ticket: @ticket,
                                   assignee_id: @params[:assignee_id], actor: @actor, true_actor: @true_actor)
    end

    # blank → rimuove; milestone fuori dal progetto del ticket → R422 dal service (anti-BOLA).
    def change_milestone
      return if skip_meta?(:milestone_id)

      Ticketing::ChangeMilestone.call(organization: @organization, ticket: @ticket,
                                      milestone_id: @params[:milestone_id], actor: @actor, true_actor: @true_actor)
    end

    # Stessa guardia del vecchio value_or_current: a corpo bloccato un metadato NON inviato resta com'è
    # (patch parziale CLI/API); prima del claim il contratto è il form completo, quindi l'assenza vale
    # rimozione e il campo va processato (blank → il service disassegna/rimuove).
    def skip_meta?(key)
      partial_metadata_update? && !param_given?(key)
    end

    # Epic padre risolto tra i ticket del PROGETTO del ticket (anti-BOLA); opzionale. blank → nil
    # (stacca il ticket dall'epic). Che sia un epic lo valida il model.
    def parent
      return @ticket.parent if partial_metadata_update? && !param_given?(:parent_id)
      return nil if @params[:parent_id].blank?

      @ticket.project.tickets.find_by(id: @params[:parent_id])
    end

    # Piattaforme risolte SCOPED all'org (anti-BOLA); subset del progetto validato sul model.
    def platforms
      return @ticket.platforms if partial_metadata_update? && !param_given?(:platform_ids)

      ids = Array(@params[:platform_ids]).reject(&:blank?)
      return [] if ids.empty?

      @organization.platforms.where(id: ids)
    end

    def param_given?(key)
      @params.key?(key) || @params.key?(key.to_s)
    end

    # Dopo il claim il corpo è immutabile, ma web/CLI/API devono poter inviare patch di soli metadati
    # senza azzerare i campi non presenti. Prima del claim conserviamo il contratto storico del form
    # completo, dove l'assenza dei campi opzionali equivale alla loro rimozione.
    def partial_metadata_update?
      @ticket.agent_workflow&.body_locked?
    end

    def value_or_current(key, current)
      return @params[key] if param_given?(key)
      return current if partial_metadata_update?

      nil
    end

    def relation_value_or_current(key, relation, current)
      return relation.find_by(id: @params[key]) if param_given?(key)
      return current if partial_metadata_update?

      nil
    end
  end
end
