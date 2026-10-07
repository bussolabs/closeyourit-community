# frozen_string_literal: true

module Ticketing
  # Approva la review di un ticket: dal suo status review-gate lo porta sul primo status done
  # (per position, seed: Resolved). Emette l'evento `review_approved` (label prima→dopo) e
  # broadcasta come un cambio stato. Nessun messaggio: l'approvazione è un fatto secco — il
  # rifiuto (RejectReview) è quello che richiede un motivo. Result pattern.
  class ApproveReview < ApplicationService
    include StatusBroadcasts
    include ::Agents::Workflows::ConcludedTicketGate

    # `broadcast_dependents: false` quando l'approvazione è una di tante nella stessa richiesta
    # (Home::Approvals::BulkApprove): il refresh delle board dei dependents lo fa il chiamante sul lotto
    # intero con UNA query, invece di una per ticket dentro il loop. Vedi StatusBroadcasts.
    # `target_status:` lets BulkApprove read the destination once for the whole selection. CYRA-1048
    def initialize(organization:, ticket:, actor: nil, true_actor: nil, broadcast_dependents: true, target_status: nil)
      @organization = organization
      @ticket = ticket
      @actor = actor
      @true_actor = true_actor
      @broadcast_dependents = broadcast_dependents
      @target_status = target_status
    end

    # Destinazione per semantica (category done), MAI per code hardcoded (lookup per-org).
    def self.target_status_for(organization)
      organization.ticket_statuses.active.category_done.ordered.first
    end

    def call
      # CYRA-611 — la seconda fermata la firma una PERSONA.
      #
      # Prima si controllava una cosa sola: che chi chiama avesse il permesso di modificare i ticket.
      # Quel permesso ce l'ha anche la macchina che ha fatto il lavoro — le serve per portare il ticket
      # in revisione quando consegna — quindi la macchina poteva firmare da sola il proprio via libera,
      # dal terminale, con un comando solo. Da lì in poi il codice andava avanti: unito, taggato,
      # rilasciato. Nessuna persona aveva guardato niente, e ogni spia restava verde.
      #
      # QUI e non nel controller: i cinque chiamanti passano tutti da questo service, e il ramo
      # autopilot delega ad `ApproveAutopilot` da dentro. Chiudere il solo comando lascia aperto il resto.
      #
      # Il discriminante è CHI CHIAMA, non a che punto è il lavoro: rifiutare «quando c'è una
      # lavorazione in corso» sembra la stessa cosa e bloccherebbe l'operatore, perché approvare a
      # lavorazione aperta È esattamente il gesto di questa fermata.
      #
      # Attore assente = rifiuto (mai `&.service?`): non sapere chi firma non è meglio che saperlo.
      return not_a_person unless @actor.is_a?(Accounts::Account) && @actor.human?
      # CYRA-630 — su un ticket già concluso non si decide, e la review è una decisione. Il caso non è
      # teorico: uno status può essere `done` E `review_gate` insieme, e lì il ticket risulta chiuso e
      # in attesa di revisione nello stesso momento. Prima approvare passava e respingere falliva —
      # ma per caso, perché non trovava dove respingere, non perché il ticket fosse chiuso.
      return concluded_ticket if concluded_ticket?

      unless @ticket.status&.review_gate?
        return Result.err(AppError.new(I18n.t("member.tickets.errors.not_in_review"), code: "R422-TICKET-006"))
      end

      # B.4 — Gate umano post-autopilot: se il ticket è in review perché l'autopilot ha consegnato
      # (workflow in awaiting_autopilot_approval), approvare avanza ai closer INVECE di chiudere — ma solo
      # se l'org ha davvero una pipeline closer configurata (agenti closer_staging + closer_production).
      # Senza, il ticket resterebbe appeso in coda closer (nessuno la serve): allora l'approvazione lo
      # chiude come una review normale (done) e completa il workflow (comportamento pre-B.4). I closer
      # restano opt-in/additivi. Va valutato PRIMA di esigere uno status done: il ramo closer non ne usa.
      workflow = @ticket.agent_workflow
      autopilot_pending = workflow&.phase == "awaiting_autopilot_approval"

      if autopilot_pending && closer_pipeline_configured?
        advance = Agents::Workflows::ApproveAutopilot.call(workflow:, actor: @actor)
        return advance if advance.err?

        # ApproveAutopilot ha già committato lo spostamento (ticket → in_progress non-gate): come il
        # path normale, segnala il cambio così board e ticket-stream si aggiornano senza reload manuale.
        broadcast_status_change(ticket: @ticket, dependents: @broadcast_dependents)
        return Result.ok(@ticket)
      end

      target = target_status
      if target.nil?
        return Result.err(AppError.new(I18n.t("member.tickets.errors.no_target_status"), code: "R422-TICKET-008"))
      end

      from_status = @ticket.status
      event = nil
      guard = Result.ok(@ticket)
      ApplicationRecord.transaction do
        # Gate dipendenze col target RISOLTO (CYRA-81): approvare porta il ticket a done (gated), quindi
        # un blocker riaperto lo trattiene in review. Ricontrollo sotto lock nella stessa transazione:
        # su blocco → rollback, nessuna mutazione e (fuori) nessun NotifyJob né broadcast.
        guard = Ticketing::DependencyGuard.call(ticket: @ticket, target_category: target.category)
        raise ActiveRecord::Rollback if guard.err?

        @ticket.update!(status: target)
        # Autopilot senza pipeline closer: l'approvazione chiude anche il workflow (done), come pre-B.4,
        # così non resta in awaiting_autopilot_approval col ticket già risolto.
        if autopilot_pending
          workflow.update!(autopilot_approved_by: @actor, autopilot_approved_at: Time.current,
                           completed_at: Time.current)
        end
        event = RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                    action: "review_approved",
                                    data: { status: { from: from_status.label, to: target.label } })
      end
      return guard if guard.err?

      Ticketing::NotifyJob.perform_later(event_id: event.id)
      broadcast_status_change(ticket: @ticket, dependents: @broadcast_dependents)
      Result.ok(@ticket)
    end

    private

    # Il messaggio nomina l'identità che sta chiamando: senza, chi si è collegato alla macchina e sta
    # usando la sua identità invece della propria vede un rifiuto e non capisce cosa rifare.
    def not_a_person
      Result.err(AppError.new(I18n.t("member.tickets.errors.approval_needs_a_person",
                                     account: @actor.respond_to?(:handle) ? @actor.handle : "-"),
                              code: "R403-TICKET-021", status: :forbidden))
    end

    def target_status
      @target_status || self.class.target_status_for(@organization)
    end

    # La stessa domanda la fa il sì automatico (CYRA-868), quindi la risposta vive in un posto solo:
    # Agents::Workflows::CloserPipeline. Due copie divergerebbero, e la seconda accoderebbe il ticket
    # in una coda che nessuno serve invece di chiuderlo pulito a done.
    def closer_pipeline_configured?
      Agents::Workflows::CloserPipeline.configured?(organization: @organization, project: @ticket.project)
    end
  end
end
