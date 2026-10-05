# frozen_string_literal: true

module Member
  # Ticket dell'organizzazione (org-wide, via i progetti). Tutti i ruoli (incl. customer) possono
  # vedere e APRIRE ticket; la gestione (edit/update/destroy/status/assignee) è admin/owner.
  # Filtri multi (param array), anti-BOLA via Current.organization.
  class TicketsController < Member::BaseController
    permission_not_required "Aprire un ticket e sfogliare quelli visibili è baseline; la gestione è gated più " \
                            "sotto (tickets.edit).",
                            only: %i[index list show new create analyze compose ask ask_query duplicates knowledge]

    # Pannello «Conoscenza correlata» della show (azione #knowledge), condiviso col gruppo errori.
    include Member::KnowledgeRelatedPanel

    # `set_ticket` PRIMA delle parti che seguono: le opzioni del modulo escludono dagli epic
    # selezionabili il ticket in modifica, e senza il ticket già caricato un epic si ritroverebbe fra
    # i propri padri possibili.
    before_action :set_ticket, only: %i[edit update destroy status assignee reviewer knowledge]
    before_action :require_ticket_permission, only: %i[edit update destroy status assignee reviewer]

    # CYRA-739 — le parti della pagina, una per compito. Erano milletrecento righe in questo file:
    # ricerca, bacheca, doppioni e opzioni del modulo si toccavano a vicenda e ogni correzione
    # atterrava in mezzo al lavoro di qualcun altro. Qui resta il ticket in sé — nasce, si modifica,
    # cambia stato, persona e traguardo.
    include Member::Tickets::Scoping        # chi entra nelle liste: filtri, ricerca, contatori
    include Member::Tickets::Boards         # bacheca
    include Member::Tickets::Listing        # la tabella
    include Member::Tickets::Detail         # la pagina di un ticket
    include Member::Tickets::Form           # le opzioni del modulo
    include Member::Tickets::Deduplication  # i doppioni, dal pannello alla pagina di confronto
    include Member::Tickets::Assistants     # analisi rapida, composizione, domanda in lingua

    def new
      # CYRA-398 — un ticket nuovo nasce sempre nel primo stato e quasi mai con la priorità più
      # bassa: proporre quei due valori è il default onesto, e lo stato non è nemmeno una scelta
      # (l'unica risposta sensata è «aperto»).
      @ticket = Ticketing::Ticket.new(project_id: params[:project_id], kind: (params[:kind].presence || :bug),
                                      title: params[:title], description: params[:description],
                                      status_id: Ticketing::FormOptions.default_status_id(Current.organization),
                                      priority_id: Ticketing::FormOptions.default_priority_id(Current.organization))
      @locked_project = lock_project(params[:project_id])
      @selected_platform_ids = preselected_platform_ids
      @selected_links = []
      # Da quale ticket arriva il consiglio (CYRA-264). Viaggia fino al create in un campo nascosto:
      # il collegamento si può scrivere solo quando il ticket nuovo esiste.
      @source_ticket_id = params[:source_ticket_id]
    end

    def create
      # Gate duplicati (solo canale web, mai i canali automatici): al primo submit, se il draft
      # somiglia MOLTO a un ticket dello STESSO progetto, si mostra il confronto invece di creare.
      # dedup_ack = esito della pagina di confronto (back/create/link).
      return handle_dedup_ack if params[:dedup_ack].present?

      # Chi ha spuntato i simili nel pannello del form ha già visto la lista e ha già deciso cosa
      # farne: rimettergli davanti la pagina di confronto sarebbe chiedergli la stessa cosa due
      # volte, ed è esattamente il passaggio di troppo che questa pagina serve a togliere.
      targets = selected_link_targets
      matches = targets.any? ? [] : dedup.gate_matches
      if matches.any?
        prepare_comparison(matches)
        # Turbo su un form POST accetta solo redirect o un render non-2xx: 200 → "Form responses
        # must redirect to another location". La pagina di confronto è interstiziale (nessun ticket
        # creato) → 422, stesso pattern di render_new_with_errors / handle_dedup_ack err.
        return render :comparison, status: :unprocessable_content
      end

      result = Ticketing::CreateTicket.call(
        organization: Current.organization, reporter: Current.account,
        true_actor: Current.true_account, params: ticket_params
      )
      if result.ok?
        linked = link_selected(result.value, targets)
        Ticketing::LinkSignals.call(ticket: result.value, actor: Current.account, organization: Current.organization,
                                    error_group_id: params[:error_group_id], metric_group_id: params[:metric_group_id])
        link_to_source_ticket(result.value)
        redirect_to member_ticket_path(result.value),
                    notice: created_notice(linked, requested: submitted_link_ids)
      else
        render_new_with_errors(result.error)
      end
    end

    def edit; end

    def update
      result = Ticketing::UpdateTicket.call(
        channel: :web,
        organization: Current.organization, ticket: @ticket, params: ticket_params,
        actor: Current.account, true_actor: Current.true_account
      )
      if result.ok?
        redirect_to member_ticket_path(@ticket), notice: t("member.tickets.updated")
      else
        @errors = @ticket.errors.to_hash
        flash.now[:alert] = result.error.message
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @ticket.destroy
      redirect_to member_tickets_path, notice: t("member.tickets.deleted")
    end

    def status
      result = Ticketing::ChangeStatus.call(
        organization: Current.organization, ticket: @ticket, status_id: params[:status_id],
        channel: :web, actor: Current.account, true_actor: Current.true_account
      )
      # Il cambio stato inline arriva da DUE origini con contratti diversi. Dalla board (fetch, senza
      # `inline`): su errore rispondiamo con lo status dell'errore invece del redirect — che il fetch
      # seguirebbe come 200 lasciando la card spostata a vuoto. Così il ticket-board vede la risposta
      # non-ok, ricarica e ripristina la card trascinata (gating server-side, es. dipendenze CYRA-81);
      # l'alert persiste ed è mostrato dopo il reload. Dal dettaglio (form Turbo col dropdown status,
      # `inline=1`, CYRA-163): niente fetch a mano, il flusso è lo stesso redirect_back con l'alert
      # usato da assignee/reviewer.
      if result.err? && params[:inline].blank?
        flash[:alert] = result.error.message
        return head(result.error.status)
      end
      respond_change(result, t("member.tickets.status_changed"))
    end

    def assignee
      result = Ticketing::AssignTicket.call(
        organization: Current.organization, ticket: @ticket, assignee_id: params[:assignee_id],
        actor: Current.account, true_actor: Current.true_account
      )
      respond_change(result, t("member.tickets.assignee_changed"))
    end

    # Cambio revisore inline (dropdown nella show). reviewer_id blank → rimuove il revisore.
    def reviewer
      result = Ticketing::SetReviewer.call(
        organization: Current.organization, ticket: @ticket, reviewer_id: params[:reviewer_id],
        actor: Current.account, true_actor: Current.true_account
      )
      respond_change(result, t("member.tickets.reviewer_changed"))
    end

    private

    # Anti-BOLA + scoping: ticket di un'altra org o su un progetto non visibile → RecordNotFound.
    def set_ticket
      @ticket = visible.tickets.find(params[:id])
    end

    def ticket_params
      params.permit(:project_id, :title, :kind, :description, :technical_analysis, :weight, :milestone_id, :due_at,
                    :parent_id, :status_id, :priority_id, :assignee_id, platform_ids: [],
                    scenarios_attributes: %i[id title position step_given step_when step_then step_expected _destroy],
                    conditions_attributes: %i[id text position _destroy])
    end

    # Record di cui cercare la conoscenza vicina (contratto Member::KnowledgeRelatedPanel).
    def knowledge_related_record = @ticket

    def respond_change(result, notice)
      # I drag consumano soltanto l'esito: seguire un redirect scaricherebbe una pagina HTML
      # inutilizzata, oltre al refresh realtime già emesso dal servizio.
      if request.format.json?
        return head :no_content if result.ok?

        flash[:alert] = result.error.message
        return head result.error.status
      end

      if result.ok?
        redirect_back fallback_location: member_ticket_path(@ticket), notice: notice
      else
        redirect_back fallback_location: member_ticket_path(@ticket), alert: result.error.message
      end
    end

    def require_ticket_permission
      key = case action_name
      when "destroy" then "tickets.delete"
      when "assignee", "reviewer" then "tickets.assign"
      else "tickets.edit"
      end
      require_permission!(key, scope: @ticket.project)
    end
  end
end
