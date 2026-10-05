# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — il suggerimento duplicati del canale web: il pannello mentre si scrive, il gate che
    # al salvataggio mostra la pagina di confronto invece di creare, e gli esiti di quella pagina
    # (torna al form, crea comunque, crea e collega). Ricerca e soglie stanno in
    # Ticketing::DedupPresenter; qui c'è quello che la pagina fa con le sue risposte.
    module Deduplication
      extend ActiveSupport::Concern

      # Suggerimento duplicati sul draft (JSON, chiamata dal form new via Stimulus). Riceve i campi
      # del form, non un testo già impastato dal JS: il pannello e la pagina di confronto devono
      # misurare LO STESSO testo contro LO STESSO archivio, altrimenti mostrano due percentuali
      # diverse per la stessa coppia e la seconda smentisce la prima ("mi diceva 91% e non mi ha
      # fermato"). Perimetro: solo lo stesso progetto, solo lavoro vivo o chiuso da poco.
      #
      # Senza progetto scelto la risposta è una lista vuota, non un errore: non aver ancora scelto il
      # progetto è uno stato normale del form. Errori → envelope standard: il JS lascia il pannello
      # com'è e il create resta sempre possibile.
      def duplicates
        result = dedup.panel_matches
        if result.nil?
          render json: { data: { tickets: [] } }
        elsif result.ok?
          render json: { data: { tickets: result.value.map { |match| dedup.payload(match) } } }
        else
          render json: { error: { code: result.error.code, message: result.error.message } },
                 status: result.error.status
        end
      end

      private

      # Il suggerimento duplicati di QUESTA richiesta (CYRA-739 → Ticketing::DedupPresenter): pannello,
      # gate del salvataggio e bersagli spuntati misurano lo stesso draft contro lo stesso archivio.
      def dedup
        @dedup ||= Ticketing::DedupPresenter.new(attributes: ticket_params, scope: visible.tickets)
      end

      # Esiti della pagina di confronto: back (ripresenta il form col draft), create/link
      # (Ticketing::ResolveDuplicate). Un err ripresenta il confronto con l'alert — se nel
      # frattempo i candidati sono spariti, fallback sul form.
      def handle_dedup_ack
        return render_draft_form if params[:dedup_ack] == "back"

        result = Ticketing::ResolveDuplicate.call(
          organization: Current.organization, reporter: Current.account,
          true_actor: Current.true_account, params: ticket_params,
          ack: params[:dedup_ack], link_ticket_ids: submitted_link_ids,
          link_kind: params[:link_kind], link_comment: params[:link_comment],
          reason: params[:dedup_reason]
        )
        if result.ok?
          # Same follow-ups as a plain create: the signals picked in the form and the ticket it came from.
          Ticketing::LinkSignals.call(ticket: result.value, actor: Current.account, organization: Current.organization,
                                      error_group_id: params[:error_group_id], metric_group_id: params[:metric_group_id])
          link_to_source_ticket(result.value)
          redirect_to member_ticket_path(result.value), notice: dedup_notice(result.value)
        else
          matches = dedup.gate_matches
          if matches.any?
            prepare_comparison(matches)
            # Errore in pagina (banner + riapertura del dialog dell'esito scelto): il flash è solo un
            # toast in basso a destra, invisibile dopo la chiusura del dialog → "non accade nulla".
            @dedup_error = result.error
            @dedup_ack = params[:dedup_ack]
            flash.now[:alert] = result.error.message
            render :comparison, status: (result.error.status || :unprocessable_content)
          else
            render_new_with_errors(result.error)
          end
        end
      end

      # La pagina di confronto ha UN form solo: le caselle dei bersagli viaggiano con qualunque
      # pulsante, anche con «Crea comunque» e «Torna al form», che con i collegamenti non c'entrano.
      # Contarle come collegamenti richiesti farebbe annunciare un collegamento mancato a chi non ne
      # aveva chiesto nessuno. Solo il ramo «crea e collega» le sta davvero domandando.
      def dedup_notice(ticket)
        requested = params[:dedup_ack] == "link" ? submitted_link_ids : []
        created_notice(ticket.links.includes(:related).map(&:related), requested: requested)
      end

      # `@matches` sono i Match (ticket + somiglianza): la pagina di confronto mostra anche la
      # percentuale, che è il numero per cui quella pagina è comparsa. `@match` è il ticket del primo,
      # cioè il più vicino: è quello che il confronto affianca colonna per colonna.
      def prepare_comparison(matches)
        @matches = matches
        @match = matches.first.ticket
        @draft = dedup.draft
        @comparison = Ticketing::ComparisonPresenter.new(existing: @match, draft: @draft)
        # Round-trip del draft negli hidden della pagina di confronto (vedi _draft_fields).
        @draft_params = ticket_params
      end

      def render_draft_form
        @ticket = dedup.draft
        @locked_project = lock_project(params[:locked_project].present? ? ticket_params[:project_id] : nil)
        @selected_platform_ids = preselected_platform_ids
        # Nessuna spunta di ritorno dal confronto, di proposito: là dentro il primo candidato è
        # PRESELEZIONATO, e "Torna al form" invia comunque tutto il form. Conservarlo vorrebbe dire
        # tornare indietro con un collegamento già scelto che nessuno ha scelto — e al salvataggio
        # dopo salterebbe pure il confronto, scrivendolo senza che l'utente lo sappia.
        @selected_links = []
        # Ramo "back" del confronto: ri-render su POST → 422 (Turbo), non 200.
        render :new, status: :unprocessable_content
      end

      def render_new_with_errors(error)
        @ticket = Ticketing::Ticket.new(ticket_params)
        @locked_project = lock_project(params[:locked_project].present? ? ticket_params[:project_id] : nil)
        @selected_platform_ids = preselected_platform_ids
        # Le spunte sopravvivono all'errore di validazione: il pannello si ricostruisce da zero al
        # ri-render, e senza questo chi ha sbagliato un campo si ritroverebbe i collegamenti scelti
        # spariti in silenzio insieme all'errore. Sono i ticket interi, non i soli id: servono a
        # ridisegnare la riga anche quando il motore dei simili non risponde — un collegamento che
        # parte da un campo invisibile, e che quindi non si può nemmeno togliere, è peggio che perderlo.
        @selected_links = selected_link_targets
        @errors = error.details || {}
        flash.now[:alert] = error.message
        render :new, status: :unprocessable_content
      end

      def submitted_link_ids = Ticketing::DedupPresenter.submitted_link_ids(params[:link_ticket_ids])

      def selected_link_targets = dedup.link_targets(submitted_link_ids)

      def link_selected(ticket, targets)
        return [] if targets.empty?

        result = Ticketing::LinkTickets.call(ticket: ticket, targets: targets, kind: :related,
                                             actor: Current.account, true_actor: Current.true_account)
        result.ok? ? result.value : []
      end

      # Il messaggio dichiara i codici collegati DAVVERO, non quelli spuntati: se un bersaglio è
      # sparito fra la spunta e il salvataggio il ticket si crea lo stesso (fail-soft), e l'unico modo
      # di accorgersene è leggerlo qui. Il caso peggiore è quando non ne è entrato nemmeno uno: il
      # ticket c'è, i collegamenti che erano stati chiesti no, e un «Ticket creato» liscio lo
      # nasconderebbe. Chi legge deve poterli rifare.
      #
      # `requested` sono gli id SPUNTATI, non i bersagli risolti: un id che non supera lo scoping non
      # arriva mai fra i bersagli, ed è proprio uno dei modi in cui un collegamento chiesto non viene
      # scritto.
      def created_notice(linked, requested: [])
        return t("member.tickets.created") if linked.empty? && requested.empty?
        return t("member.tickets.duplicates.created_not_linked") if linked.empty?

        t("member.tickets.duplicates.created_linked", count: linked.size,
                                                      codes: linked.map(&:code).to_sentence)
      end

      # Il ticket nato da un consiglio resta legato a quello che lo ha suggerito. `find_by` sull'org
      # corrente chiude il caso cross-tenant prima ancora della validazione del modello; il progetto
      # invece NON si restringe, di proposito: un consiglio nasce spesso su un ticket di un altro
      # progetto ed è proprio quel salto che vale la pena registrare.
      def link_to_source_ticket(ticket)
        source_id = params[:source_ticket_id]
        return if source_id.blank?

        source = visible.tickets.find_by(id: source_id)
        return if source.nil?

        Ticketing::LinkTickets.call(ticket: ticket, targets: [ source ], kind: :related,
                                    actor: Current.account, true_actor: Current.true_account)
      end
    end
  end
end
