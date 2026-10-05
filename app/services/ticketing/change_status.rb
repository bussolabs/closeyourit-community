# frozen_string_literal: true

module Ticketing
  # Cambia lo status di un ticket (inline dalla lista/dettaglio/board). Lo status deve appartenere
  # all'org (anti-BOLA). Result pattern. Dopo il commit broadcasta in tempo reale lo spostamento
  # della card sul board e il badge stato (StatusBroadcasts, condiviso con le review decision).
  class ChangeStatus < ApplicationService
    include StatusBroadcasts

    # CYRA-609 — `channel:` è OBBLIGATORIO e senza default. Da DOVE arriva la richiesta decide se può
    # spostare lo stato di una lavorazione in corso, e un default renderebbe quella decisione implicita:
    # una porta nuova erediterebbe in silenzio i permessi della più permissiva. Il valore ignoto o nullo
    # vale `:cli`, cioè il più stretto — fail-closed.
    # CYRA-614 — `:workflow` è il quarto canale, e non è una scappatoia per le macchine.
    #
    # CYRA-609 ha chiuso le porte automatiche perché una macchina poteva DICHIARARE di aver finito e
    # spostare il ticket sulla propria parola. Questo canale è l'opposto: lo usa il sistema dopo aver
    # aperto la proposta con le sue mani, messo per iscritto quale codice c'è dentro e letto l'esito
    # dei controlli su quel codice. È un fatto osservato, non una dichiarazione — ed è esattamente la
    # cosa che quelle porte proteggevano.
    #
    # Ha UN solo chiamante (`Agents::Candidates::Verify`) e resta stretto per costruzione: chi lo usa
    # deve avere guardato. Il cancello dei prerequisiti, l'evento in cronologia e il broadcast valgono
    # come per gli altri canali — è il motivo per cui passa da qui invece di scrivere lo status a mano.
    CHANNELS = %i[web cli webhook workflow].freeze

    # CYRA-622 — `dependency_mode` è quale domanda si fa ai prerequisiti. Il default `:released` non
    # cambia per nessuno dei chiamanti di oggi: chi chiude un ticket a mano continua a pretendere che
    # il prerequisito sia vivo in produzione. Lo alza soltanto la proiezione fase→stato, che scrive un
    # fatto osservato e non una decisione.
    # `broadcast` esiste per un solo caso: quando il cambio di stato è la conseguenza di una decisione
    # che il chiamante sta già annunciando lui — l'approvazione del lavoro, che annuncia una volta
    # sola e sa se è una di cento. Due annunci sulla stessa mossa fanno rinfrescare la bacheca due
    # volte e, in un'approvazione di gruppo, rifanno per ogni card il giro che era stato messo in
    # fondo apposta.
    def initialize(organization:, ticket:, status_id:, channel:, actor: nil, true_actor: nil,
                   dependency_mode: :released, broadcast: true)
      @organization = organization
      @ticket = ticket
      @status_id = status_id
      @channel = CHANNELS.include?(channel&.to_sym) ? channel.to_sym : :cli
      @actor = actor
      @true_actor = true_actor
      @dependency_mode = dependency_mode
      @broadcast = broadcast
    end

    def call
      status = @organization.ticket_statuses.find_by(id: @status_id)
      if status.nil?
        return Result.err(AppError.new(I18n.t("member.tickets.errors.invalid_status"), code: "R422-TICKET-003"))
      end
      # No-op: stesso status → nessuna mutazione, nessun evento (niente rumore in timeline), nessun broadcast.
      return Result.ok(@ticket) if status.id == @ticket.status_id

      from_status = @ticket.status
      event = nil
      guard = Result.ok(@ticket)
      ApplicationRecord.transaction do
        # CYRA-609 — la leva ha un padrone solo. Finché una lavorazione è avviata e non è conclusa, lo
        # stato non si sposta dai canali automatici. Prima potevano spostarlo in tre: tu dalla pagina, la
        # macchina dal terminale, e GitHub unendo il codice — e nessuna delle tre sapeva cosa facevano le
        # altre. Bastava che una segnasse «da revisionare» a lavoro ancora in corso, o «fatto» prima che
        # il rilascio partisse, perché quella parola smettesse di dire a che punto è il lavoro: la coda
        # non pescava più il ticket, la lavorazione restava appesa, e nessuno veniva avvisato.
        #
        # DENTRO la transazione e prima del guard dipendenze: se rifiuta, rollback e non resta niente —
        # nessun update, nessun evento in timeline, nessuna notifica.
        guard = workflow_guard
        raise ActiveRecord::Rollback if guard.err?

        # Gate dipendenze DENTRO la transazione (CYRA-81): il guard prende il lock su ticket + blocker e
        # rivaluta i prerequisiti col target RISOLTO. Se è gated e resta un blocker aperto → rollback,
        # nessun update/evento e (fuori dalla transazione) nessun NotifyJob né broadcast.
        guard = Ticketing::DependencyGuard.call(ticket: @ticket, target_category: status.category,
                                                mode: @dependency_mode)
        raise ActiveRecord::Rollback if guard.err?

        @ticket.update!(status: status)
        event = RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                    action: "status_changed",
                                    # simplecov:disable status_id è null:false → un ticket persistito ha sempre uno
                                    # status di partenza; l'arm `from_status&.label` nil è irraggiungibile.
                                    data: { status: { from: from_status&.label, to: status.label } })
        # simplecov:enable
      end
      return guard if guard.err?

      # Notifiche watcher + broadcast realtime, DOPO il commit — quello vero, non solo quello della
      # transazione qui sopra.
      #
      # CYRA-675: «post-commit» valeva finché questo service era il più esterno. Chiamato DENTRO la
      # transazione di un altro (Agents::Attempts::Deliver quando chiude un ticket già fatto,
      # Agents::Probes::Observe quando vede il rilascio in piedi) la transazione interna non committa
      # niente, e il job partiva su un evento non ancora visibile: `NotifyJob` fa `find_by` e su nil
      # esce in silenzio — la notifica non arrivava a nessuno, senza un errore da nessuna parte. Il
      # broadcast aveva lo stesso difetto al contrario: mostrava uno stato che poteva ancora tornare
      # indietro. `after_all_transactions_commit` esegue subito quando non c'è nessuna transazione
      # aperta, quindi per tutti gli altri chiamanti non cambia niente.
      ActiveRecord.after_all_transactions_commit do
        Ticketing::NotifyJob.perform_later(event_id: event.id)
        broadcast_status_change(ticket: @ticket) if @broadcast
      end
      Result.ok(@ticket)
    end

    private

    # Sui ticket che nessuna macchina ha mai preso in mano non cambia niente: si spostano come sempre,
    # da ogni parte. Il blocco riguarda solo i lavori davvero in corso.
    def workflow_guard
      workflow = @ticket.agent_workflow
      return Result.ok(@ticket) unless workflow&.work_in_progress?
      return Result.ok(@ticket) if @channel == :workflow
      return Result.ok(@ticket) if @channel == :web && human_holder?(workflow)

      Result.err(AppError.new(I18n.t("member.tickets.errors.workflow_owns_status"),
                              code: "R409-TICKET-020", status: :conflict))
    end

    # Dalla pagina lo sposti tu, a mano, a una condizione: aver preso in carico il ticket. È un clic, e
    # serve a rendere la mossa TUA — visibile a tutti — invece di un ripensamento anonimo.
    #
    # `Lease#human?` NON basta: è vero anche per un account di servizio, cioè per la macchina che passa
    # dal terminale. Qui si pretende una persona: `kind: human`.
    def human_holder?(workflow)
      return false unless @actor.is_a?(Accounts::Account) && @actor.human?

      lease = Agents::Lease.find_by(ticket_id: @ticket.id)
      # `held_by?` ragiona sul TITOLARE (host o account), non sul record: passargli direttamente
      # l'account confronterebbe `kind` — che su un account vale "human"/"service" — con `:account`,
      # e nessuno avrebbe mai la presa in carico.
      lease.present? && lease.active_at?(Time.current) &&
        lease.held_by?(Agents::Leases::Holder.account(@actor))
    end
  end
end
