# frozen_string_literal: true

module Ticketing
  # Riga di cronologia/audit di un ticket: chi (actor; true_actor per impersonation),
  # cosa (action) e i dettagli prima→dopo (data). Le label nel `data` sono UMANE e
  # snapshottate, così la cronologia resta veritiera anche se uno status/priority viene
  # poi rinominato. Tabella `ticketing_events` (prefisso namespace, vedi Ticketing).
  class Event < ApplicationRecord
    # Allow-list dei tipi evento. Stringhe (non enum): leggibili in DB, stabili ai riordini.
    # Niente `deleted` (eliminazione ticket intero non tracciata) né `commented`
    # (il commento è già una riga della timeline — sarebbe doppio).
    # `agent_eligibility_evaluated` nasce SENZA actor (l'ha deciso il server AI, non una persona):
    # è il caso d'uso per cui `actor` è optional. `agent_eligibility_overridden` ha sempre l'attore.
    # `clarification_requested` (CYRA-262) traccia la domanda posta da chi deve approvare: il testo
    # vive nel commento, qui resta il fatto — ed è ciò che dice alla pila delle approvazioni che la
    # palla è passata a qualcun altro.
    # `work_context_captured` (CYRA-76) è l'evento SINTETICO dello snapshot della Guidance alla presa
    # in carico: il `data` porta solo digest, versione e conteggi, MAI il contenuto (senza dati sensibili).
    # `dependency_added`/`dependency_removed` (CYRA-82) tracciano l'aggiunta/rimozione di un prerequisito
    # (Connections::TicketDependency): il `data` porta code e title SNAPSHOTTATI del blocker, così la
    # frase resta veritiera anche se quel ticket viene poi rinominato o cancellato.
    # `already_done` (CYRA-675) è il ticket chiuso perché chi doveva pianificarlo ha trovato il lavoro
    # già fatto nel codice: nel `data` restano il riassunto e i file che lo provano, perché una
    # chiusura senza il posto in cui guardare non si può rimettere in discussione.
    # `autopilot_auto_approved` (CYRA-868) è la consegna passata SENZA che nessuno abbia cliccato: nel
    # `data` restano i controlli su cui è passata e l'esito della rilettura, perché una decisione che
    # nessuno ha preso va poter rimessa in discussione da chi la legge. Nasce SENZA actor, col solo
    # `actor_name` di sistema: dietro non c'era una persona.
    ACTIONS = %w[
      created updated status_changed assigned unassigned reviewer_changed milestone_changed
      comment_deleted attached attachment_removed review_rejected review_approved linked
      branch_created pull_request_opened pull_request_merged pull_request_closed
      agent_eligibility_evaluated agent_eligibility_overridden clarification_requested
      work_context_captured dependency_added dependency_removed dependency_blocked
      pull_request_autoclose_declined already_done
      question_asked question_answered question_closed
      autopilot_auto_approved
    ].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :events
    belongs_to :actor, class_name: "Accounts::Account", optional: true, inverse_of: :actor_events
    belongs_to :true_actor, class_name: "Accounts::Account", optional: true, inverse_of: :true_actor_events

    validates :action, presence: true, inclusion: { in: ACTIONS }
    # Integrità tenant: l'org denormalizzata deve combaciare con quella reale del ticket
    # (via project). Difesa coerente con Ticket#status_and_priority_match_organization e
    # Comment#author_belongs_to_organization: lo scoping d'audit passa da organization_id,
    # una divergenza sarebbe un buco di isolamento silenzioso.
    validate :organization_matches_ticket

    # Tie-break su :id: a parità di created_at (eventi nello stesso istante) l'ordine è
    # comunque totale e deterministico (created_at da solo non basta — vedi timeline show).
    scope :chronological, -> { order(:created_at, :id) }

    # Vero quando il fatto è avvenuto sotto impersonation (god ≠ account percepito).
    def impersonated?
      true_actor_id.present? && true_actor_id != actor_id
    end

    private

    def organization_matches_ticket
      ticket_org_id = ticket&.project&.organization_id
      return if ticket_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != ticket_org_id
    end
  end
end
