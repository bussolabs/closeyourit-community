# frozen_string_literal: true

module Ticketing
  # Esito del gate duplicati alla creazione (canale Member web): l'utente ha visto la pagina di
  # confronto e ha scelto. `create` = crea comunque, con la motivazione (obbligatoria) appesa alla
  # descrizione. `link` = crea E collega i preesistenti spuntati (uno o più: la pagina di confronto
  # elenca tutti i simili trovati, e capita che il lavoro nuovo tocchi più d'uno) con il tipo scelto
  # e un commento opzionale su ciascuno. La creazione resta Ticketing::CreateTicket, la scrittura
  # dei collegamenti Ticketing::LinkTickets.
  class ResolveDuplicate < ApplicationService
    LINK_KINDS = %w[duplicate related].freeze

    def initialize(organization:, reporter:, params:, ack:, true_actor: nil,
                   link_ticket_ids: nil, link_kind: nil, link_comment: nil, reason: nil)
      @organization = organization
      @reporter = reporter
      @params = params
      @ack = ack.to_s
      @true_actor = true_actor
      @link_ticket_ids = Array(link_ticket_ids).reject(&:blank?).uniq
      @link_kind = link_kind.to_s
      @link_comment = link_comment.to_s.strip
      @reason = reason.to_s.strip
    end

    def call
      case @ack
      when "create" then create_with_reason
      when "link" then create_and_link
      else
        Result.err(AppError.new(I18n.t("member.tickets.comparison.errors.invalid_ack"),
                                code: "R422-TICKET-011"))
      end
    end

    private

    # "Crea comunque": la motivazione è il contratto del gate (finisce in descrizione, così la
    # scelta resta leggibile sul ticket, non solo nell'audit).
    def create_with_reason
      if @reason.blank?
        return Result.err(AppError.new(I18n.t("member.tickets.comparison.errors.reason_required"),
                                       code: "R422-TICKET-009"))
      end

      original = @params[:description].to_s.strip.presence
      reason_text = "---\n#{I18n.t('member.tickets.comparison.reason_prefix')}: #{@reason}"
      with_reason = [ original, reason_text ].compact.join("\n\n")

      # La motivazione la appende il SISTEMA: non deve far sforare il tetto a una descrizione che
      # l'utente aveva scritto dentro il limite, né rubarle spazio a colpi di ellissi. Se non ci sta,
      # il ticket nasce con la descrizione INTATTA e la motivazione va in un commento — INTERA, che
      # lì quel tetto non c'è: resta leggibile sul ticket (in timeline invece che nel corpo) e
      # nessuno perde il proprio testo. Senza descrizione il corpo non può restare vuoto (il ticket
      # non sarebbe salvabile): ci va la motivazione accorciata, l'integrale resta nel commento.
      # Misurata come la misurerà il model (i param arrivano dal browser coi CRLF): sulla lunghezza
      # grezza si sposterebbe in un commento anche una motivazione che invece ci sarebbe stata.
      fits = Ticketing::Ticket.normalize_value_for(:description, with_reason).length <=
             Ticketing::Constants::DESCRIPTION_MAX_CHARS
      fallback = original || reason_text.truncate(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
      description = fits ? with_reason : fallback

      result = CreateTicket.call(
        organization: @organization, reporter: @reporter, true_actor: @true_actor,
        params: @params.to_h.symbolize_keys.merge(description: description)
      )
      return result if fits || result.err?

      add_reason_comment(result.value, reason_text)
      result
    end

    # Fallback della motivazione quando non entra nella descrizione. Come add_optional_comment, un
    # fallimento qui non annulla la creazione già committata: logga e prosegue.
    def add_reason_comment(ticket, body)
      result = AddComment.call(ticket: ticket, author: @reporter, params: { body: body })
      Rails.logger.warn("ResolveDuplicate: motivazione non commentata (#{result.error.code})") if result.err?
    end

    # "Crea e collega": bersagli risolti PRIMA di creare (fail-fast, niente ticket orfano se sono
    # tutti invalidi). Stesso progetto del draft: il gate propone solo candidati lì dentro.
    def create_and_link
      unless LINK_KINDS.include?(@link_kind)
        return Result.err(AppError.new(I18n.t("member.tickets.comparison.errors.invalid_kind"),
                                       code: "R422-TICKET-010"))
      end

      # Nessuna casella spuntata è una cosa diversa da un id che non esiste: chi ha tolto tutte le
      # spunte e ha premuto "Crea e collega" si sentiva rispondere "Ticket da collegare non trovato",
      # che sembra un guasto e non dice cosa fare.
      if @link_ticket_ids.empty?
        return Result.err(AppError.new(I18n.t("member.tickets.comparison.errors.no_target_selected"),
                                       code: "R422-TICKET-019"))
      end

      targets = link_targets
      if targets.empty?
        return Result.err(AppError.new(I18n.t("member.tickets.comparison.errors.target_not_found"),
                                       code: "R404-TICKET-003", status: :not_found))
      end

      result = CreateTicket.call(organization: @organization, reporter: @reporter,
                                 true_actor: @true_actor, params: @params)
      return result if result.err?

      ticket = result.value
      linked = LinkTickets.call(ticket: ticket, targets: targets, kind: @link_kind,
                                actor: @reporter, true_actor: @true_actor)
      linked.value.each { |target| add_optional_comment(target) }
      Result.ok(ticket)
    end

    # Bersagli scoped: visibili al reporter E nello stesso progetto del draft (anti-BOLA +
    # invariante del gate). Un id fuori scope non esiste, per definizione. `includes(:project)`
    # perché la cronologia legge l'organizzazione passando dal progetto.
    def link_targets
      visible_projects = Authorization::VisibleScope.new(account: @reporter, organization: @organization).projects
      Ticketing::Ticket.where(project_id: visible_projects.select(:id))
                       .where(project_id: @params[:project_id])
                       .includes(:project)
                       .where(id: @link_ticket_ids)
                       .to_a
    end

    # Commento su ciascun preesistente collegato (opzionale): arricchisce il vecchio ticket col
    # contesto del nuovo. Un fallimento qui non annulla la creazione già committata: logga e prosegue.
    def add_optional_comment(target)
      return if @link_comment.blank?

      result = AddComment.call(ticket: target, author: @reporter, params: { body: @link_comment })
      Rails.logger.warn("ResolveDuplicate: commento non aggiunto (#{result.error.code})") if result.err?
    end
  end
end
