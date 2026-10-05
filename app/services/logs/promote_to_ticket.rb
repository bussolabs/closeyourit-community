# frozen_string_literal: true

module Logs
  # CYRA-347 — da un rallentamento si apre un ticket con un pulsante; da un messaggio no, si poteva
  # solo agganciare un ticket che esisteva già. Ma il messaggio è spesso il PRIMO posto dove si vede
  # un problema nuovo: proprio lì il percorso «trovo, apro il lavoro» si interrompeva, e restava da
  # ricopiare il testo a mano in un'altra area.
  #
  # Non eredita da Observability::PromoteToTicket: quella base vive su un `group` che possiede una
  # colonna `ticket_id` e sa dire `promoted?`. Un log non è un gruppo — è una riga di uno stream
  # append-only, e il suo legame col ticket è il collegamento manuale che già esiste (Logs::Link).
  #
  # Deduplica: lo stesso messaggio si ripete decine di volte (il caso reale è un errore di Resend
  # ripetuto), e senza un controllo ogni riga aprirebbe il suo ticket. Se un messaggio IDENTICO dello
  # stesso progetto è già stato promosso, questa riga si collega a QUEL ticket invece di crearne un
  # altro — e chi promuove lo legge, non lo scopre dopo.
  class PromoteToTicket < ApplicationService
    Outcome = Data.define(:ticket, :reused)

    TITLE_MAX = 120

    def initialize(entry:, reporter:, true_actor: nil)
      @entry = entry
      @reporter = reporter
      @true_actor = true_actor
    end

    def call
      existing = existing_ticket
      return link(existing, reused: true) if existing

      result = Ticketing::CreateTicket.call(
        organization: @entry.project.organization, reporter: @reporter,
        true_actor: @true_actor, params: ticket_params
      )
      return result unless result.ok?

      link(result.value, reused: false)
    end

    private

    # Il ticket già aperto da un messaggio identico dello stesso progetto. Identico e non "simile":
    # una somiglianza approssimata collegherebbe cose diverse, ed è peggio di due ticket.
    def existing_ticket
      twins = Logs::Entry.where(project_id: @entry.project_id, message: @entry.message).select(:id)
      Logs::Link.where(log_entry_id: twins, linkable_type: "Ticketing::Ticket")
                .order(created_at: :desc).first&.linkable
    end

    def link(ticket, reused:)
      result = Logs::Links::Attach.call(log_entry: @entry, linkable: ticket, actor: @reporter)
      return result unless result.ok?

      Result.ok(Outcome.new(ticket:, reused:))
    end

    # Il titolo è la prima riga del messaggio, tagliata: un log può essere lunghissimo e il titolo di
    # un ticket si legge in elenco. Il messaggio intero resta nella descrizione, dove serve.
    def ticket_params
      {
        project_id: @entry.project_id,
        kind: :bug,
        title: title,
        description: @entry.message.to_s.truncate(Ticketing::Constants::DESCRIPTION_MAX_CHARS),
        technical_analysis: technical_details,
        status_id: default_status&.id,
        priority_id: default_priority&.id
      }
    end

    def title
      first_line = @entry.message.to_s.lines.first.to_s.strip
      "[#{@entry.level}] #{first_line}".truncate(TITLE_MAX)
    end

    # Ambiente, versione e origine del messaggio: sono i dati che dicono DOVE è successo, e vivono nel
    # registro tecnico, non nel corpo che legge chi non sviluppa.
    def technical_details
      parts = []
      parts << "Environment: #{@entry.environment}" if @entry.environment.present?
      parts << "Release: #{@entry.release}" if @entry.release.present?
      parts << "Logger: #{@entry.logger_name}" if @entry.logger_name.present?
      parts << "Trace: #{@entry.trace_id}" if @entry.trace_id.present?
      parts << "Occurred at: #{@entry.occurred_at.iso8601}" if @entry.occurred_at.present?
      parts.presence&.join("\n")&.truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
    end

    # Stessi default della promozione di un errore o di un rallentamento: un ticket che nasce da un
    # segnale di monitoraggio parte aperto e alto, ovunque nasca.
    def default_status
      organization.ticket_statuses.find_by(code: "open") || organization.ticket_statuses.active.ordered.first
    end

    def default_priority
      organization.ticket_priorities.find_by(code: "high") || organization.ticket_priorities.active.ordered.first
    end

    def organization = @entry.project.organization
  end
end
