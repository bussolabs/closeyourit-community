# frozen_string_literal: true

module Home
  module Approvals
    # Che ne è stato di una richiesta che il link punta ma la coda non ha più (CYRA-325).
    #
    # Il link `?item=` è il modo naturale di dire a un collega «decidi tu questo», e con decine di
    # richieste e più persone il caso «qualcun altro l'ha già decisa» è la norma: prima buttava fuori
    # con il 404 di sistema, in inglese e senza menu. Qui si risponde alla sola domanda che serve —
    # chi l'ha decisa e quando — e la coda resta dov'era.
    #
    # La decisione si legge dal RECORD, non dalla cronologia: `approved_at`/`cancelled_at` e i loro
    # autori sono il dato autoritativo, mentre gli eventi sono una narrazione che può mancare o
    # cambiare nome. L'unica eccezione è la review, che vive sullo stato del ticket e la cui
    # decisione è per costruzione un evento.
    #
    # Sola lettura e dentro lo scope visibile: una richiesta di un progetto che non vedo torna
    # `nil`, indistinguibile da una mai esistita. È voluto — il link non deve rivelare l'esistenza
    # di ciò che non ti compete.
    class Settled < ApplicationService
      REVIEW_ACTIONS = %w[review_approved review_rejected].freeze

      # Il registro: famiglia → lettore del suo esito, sulle stesse chiavi di Detail::KINDS (una spec
      # le confronta). Il nome composto a runtime nascondeva questi quattro metodi a chi cerca nel
      # codice e teneva implicito l'elenco dei casi coperti. CYRA-801
      OUTCOME_BUILDERS = { "agent_plan" => :settled_agent_plan, "review" => :settled_review,
                           "clarification" => :settled_clarification,
                           "secret_change" => :settled_secret_change }.freeze

      Outcome = Data.define(:kind, :ticket, :actor_name, :at) do
        # Sappiamo quando è stata decisa, o solo che non è più in coda?
        def documented? = at.present?
      end

      def initialize(account:, organization:, visible_projects:, visible_tickets:, key:)
        @account = account
        @organization = organization
        @visible_projects = visible_projects
        @visible_tickets = visible_tickets
        @kind, @id = key.to_s.split(":", 2)
      end

      # Come in Detail: famiglia ignota → `nil`, e il `fetch` parla solo se il registro si dimentica
      # una famiglia del vocabolario. CYRA-801
      def call
        return nil unless Detail::KINDS.include?(@kind) && @id.present?

        send(OUTCOME_BUILDERS.fetch(@kind))
      end

      private

      def outcome(ticket: nil, actor_name: nil, at: nil) = Outcome.new(kind: @kind, ticket:, actor_name:, at:)

      def settled_agent_plan
        workflow = ::Agents::Workflow.includes(:approved_by, :autopilot_approved_by, :cancelled_by).find_by(id: @id)
        ticket = ticket_of(workflow&.ticket_id)
        return outcome if ticket.nil?

        # L'ultima decisione presa sulla lavorazione: approvazione del piano, via libera
        # all'autopilot, annullamento. Si prende la più recente, che è quella che ha chiuso.
        decision = [ [ workflow.approved_at, workflow.approved_by ],
                     [ workflow.autopilot_approved_at, workflow.autopilot_approved_by ],
                     [ workflow.cancelled_at, workflow.cancelled_by ] ]
                   .select { |at, _| at.present? }.max_by(&:first)
        outcome(ticket:, actor_name: decision&.last&.name.presence || system_name(workflow, decision),
                at: decision&.first)
      end

      # CYRA-868 — una decisione registrata senza nessuno che l'abbia firmata è il sì automatico dopo
      # i controlli verdi: si dice, invece di lasciare «qualcun altro», che è falso e non aiuta chi
      # sta cercando di capire com'è andata. Vale solo su quella decisione: un'approvazione del piano
      # o un annullamento hanno sempre un autore, e senza resta ignoto com'era.
      def system_name(workflow, decision)
        return nil if decision.nil? || decision.first != workflow.autopilot_approved_at

        I18n.t("member.tickets.activity.system.autopilot")
      end

      def settled_review
        ticket = ticket_of(@id)
        return outcome if ticket.nil?

        event = ::Ticketing::Event.where(ticket_id: ticket.id, action: REVIEW_ACTIONS).order(created_at: :desc).first
        outcome(ticket:, actor_name: event&.actor_name, at: event&.created_at)
      end

      def settled_clarification
        clarification = ::Agents::Clarification.includes(:workflow).find_by(id: @id)
        ticket = ticket_of(clarification&.workflow&.ticket_id)
        return outcome if ticket.nil?

        # Alla domanda si risponde con un commento: l'autore di quel commento è chi ha risposto.
        answer = clarification.response_comment_id && ::Ticketing::Comment.includes(:author).find_by(id: clarification.response_comment_id)
        outcome(ticket:, actor_name: answer&.author&.name, at: clarification.answered_at)
      end

      def settled_secret_change
        request = ::Secrets::ChangeRequest.includes(:decided_by, :project).find_by(id: @id)
        return outcome if request.nil? || !@visible_projects.exists?(id: request.project_id)

        outcome(actor_name: request.decided_by&.name, at: request.decided_at)
      end

      def ticket_of(ticket_id)
        return nil if ticket_id.blank?

        @visible_tickets.includes(:project, :status).find_by(id: ticket_id)
      end
    end
  end
end
