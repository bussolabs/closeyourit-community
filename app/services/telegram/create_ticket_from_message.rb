# frozen_string_literal: true

module Telegram
  # /nuovo-ticket [CHIAVE] <testo>: apre un ticket (kind bug, sempre ammesso) riusando il service di
  # dominio Ticketing::CreateTicket. Corpo "semplice": prima riga = titolo, tutto il testo = descrizione
  # (così requires_some_body è sempre soddisfatto). Progetto: chiave esplicita se il primo token la
  # somiglia E risolve a un progetto visibile, altrimenti il progetto attivo dell'account. Se il
  # messaggio porta una foto/documento (caption), viene scaricata e allegata (Ticketing::AttachToTicket).
  class CreateTicketFromMessage < ApplicationService
    include Telegram::Respondable

    TITLE_MAX = 120
    KEY_LIKE = /\A[A-Za-z0-9]{1,4}\z/

    def initialize(account:, chat_id:, args:, message: nil)
      @account = account
      @chat_id = chat_id
      @args = args.to_s.strip
      @message = message
      @body = nil
    end

    def call
      return empty if @args.blank?

      project = resolve_project
      return no_project if project.nil?

      create(project)
    end

    private

    # Chiave esplicita solo se il primo token la somiglia E risolve a un progetto visibile con del testo
    # a seguire; altrimenti il progetto attivo e tutto il testo è il corpo. Evita di scambiare una parola
    # corta in maiuscolo (es. "API") per una chiave quando non esiste un progetto con quella chiave.
    def resolve_project
      first, rest = @args.split(/\s+/, 2)
      if first&.match?(KEY_LIKE) && rest.present?
        by_key = Telegram::ResolveProject.call(account: @account, key: first)
        if by_key.ok?
          @body = rest
          return by_key.value
        end
      end

      active = Telegram::ResolveProject.call(account: @account, key: nil)
      return nil unless active.ok?

      @body = @args
      active.value
    end

    def create(project)
      organization = project.organization
      result = Ticketing::CreateTicket.call(
        organization: organization, reporter: @account, true_actor: @account,
        params: {
          project_id: project.id, kind: :bug,
          title: title, description: description,
          status_id: default_status(organization)&.id,
          priority_id: default_priority(organization)&.id
        }
      )
      return failed(result.error) unless result.ok?

      attach_and_confirm(result.value)
    end

    def attach_and_confirm(ticket)
      media = telegram_media(@message)
      return confirm(ticket, "ticket.created") if media.nil?

      file = Telegram::DownloadFile.call(file_id: media[:file_id], filename: media[:filename])
      attached = file.ok? &&
                 Ticketing::AttachToTicket.call(ticket: ticket, files: [ file.value ], actor: @account, true_actor: @account).ok?
      confirm(ticket, attached ? "ticket.created_photo" : "ticket.created_photo_failed")
    end

    def confirm(ticket, key)
      reply(key, code: ticket.code, title: ticket.title, url: ticket_url(ticket))
      Result.ok(ticket)
    end

    def title
      @body.split("\n", 2).first.to_s.strip.truncate(TITLE_MAX)
    end

    # Un messaggio Telegram arriva a 4.096 caratteri: oltre il tetto del ticket. Qui si tronca invece
    # di far fallire la validazione — chi segnala un bug da chat non deve vedersi rifiutare la
    # segnalazione per una questione di lunghezza (stessa scelta già fatta per il titolo).
    def description
      @body.to_s.truncate(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
    end

    def default_status(organization)
      organization.ticket_statuses.find_by(code: "open") ||
        organization.ticket_statuses.active.ordered.first
    end

    def default_priority(organization)
      organization.ticket_priorities.find_by(code: "medium") ||
        organization.ticket_priorities.active.ordered.first
    end

    def empty
      reply("ticket.empty")
      Result.err(AppError.new("testo ticket mancante", code: "R422-TELEGRAM-009"))
    end

    def no_project
      reply("ticket.no_project")
      Result.err(AppError.new("nessun progetto attivo", code: "R404-TELEGRAM-003", status: :not_found))
    end

    def failed(error)
      reply("ticket.failed", error: error.message)
      Result.err(error)
    end
  end
end
