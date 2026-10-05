# frozen_string_literal: true

module Knowledge
  # Crea una pagina KB collegata a N progetti e/o N gruppi (risolti SCOPED alla visibilità
  # dell'autore, anti-BOLA), oppure org-wide (nessuno scope) — quest'ultimo solo per chi ha accesso
  # pieno. author = l'account il cui accesso è stato usato (created_by). Result pattern; embedding
  # post-commit (mai after_commit).
  #
  # CYRA-419: chi ha scritto materialmente il testo è un'altra cosa e lo dichiara IL CANALE, non il
  # payload — `authored_by` (:human dal web, :agent da chi propone) e `author_origin` (nome
  # dell'assistente, della skill o del canale). Default nil = origine non registrata: un canale che
  # non la dichiara non fa attribuire la pagina a una persona.
  class CreatePage < ApplicationService
    def initialize(organization:, author:, params:, authored_by: nil, author_origin: nil)
      @organization = organization
      @author = author
      @params = params
      @authored_by = authored_by
      @author_origin = author_origin
    end

    def call
      # Retrocompat: un canale che manda ancora `project_id` singolo vale come project_ids: [id].
      project_ids = resolve_ids(@params[:project_ids] || Array(@params[:project_id]), visible_projects)
      group_ids = resolve_ids(@params[:group_ids], visible_groups)
      return err("R404-KNOWLEDGE-001", :project_not_found, :not_found) if project_ids.nil? || group_ids.nil?
      # Pagina org-wide: solo full-access, altrimenti l'autore creerebbe una pagina che poi non
      # rivedrebbe (le org-wide sono visibili solo a chi ha accesso pieno).
      if project_ids.empty? && group_ids.empty? && !full_access?
        return err("R403-KNOWLEDGE-001", :scope_required, :forbidden)
      end

      # CYRA-429: una proposta da assistente deve arrivare coi due livelli distinti. Se il corpo è
      # scritto in linguaggio tecnico e la parte tecnica non c'è, la pagina nascerebbe con un livello
      # semplice che semplice non è — e il difetto arriverebbe in revisione già scritto. Chi scrive
      # dal web non passa da qui: riceve l'avviso dopo il salvataggio e corregge quando vuole.
      if in_review? && @params[:tech_spec].blank? && technical_body?
        return err("R422-KNOWLEDGE-012", :two_levels_required, :unprocessable_content)
      end

      # CYRA-764: il revisore automatico, PRIMA della transazione (chiama la rete). Un rifiuto è un
      # 422 con le violazioni; un servizio giù è un 503 e la pagina non entra (fail-closed).
      review = Knowledge::ReviewPage.call(title: @params[:title], body: @params[:body], tech_spec: @params[:tech_spec],
                                          kind: @params[:kind].presence || :note, tags: @params[:tags],
                                          scope: Knowledge::Review.scope_for(account: @author, organization: @organization))
      return review if review.err?
      return Knowledge::Review.rejection(review.value) if review.value&.rejected?

      page = Knowledge::Page.new(
        organization: @organization,
        created_by: @author,
        title: @params[:title],
        body: @params[:body],
        tech_spec: @params[:tech_spec],
        tags: @params[:tags],
        kind: @params[:kind].presence || :note,
        status: in_review? ? :in_review : :published,
        review_note: (@params[:review_note] if in_review?),
        # CYRA-768 — una pagina che nasce già pubblicata (il web) non passa mai da Approve: se il
        # conto non partisse qui, resterebbe vera per sempre. Una proposta invece aspetta: la data
        # gliela mette chi la accetta.
        review_after: (Knowledge::ReviewSchedule.next_for(kind: @params[:kind].presence || :note) unless in_review?),
        **Knowledge::Page.authorship_attributes(kind: @authored_by, origin: @author_origin),
        **Knowledge::Review.page_attributes(review.value)
      )
      # with_attached_icon_image: l'assegnazione autosalva i progetti/gruppi → la validazione Iconable
      # legge l'icona; precaricarla evita l'N+1 su active_storage (come Knowledge::Books::Save).
      page.projects = Projects::Project.where(id: project_ids).with_attached_icon_image
      page.groups = Projects::Group.where(id: group_ids).with_attached_icon_image

      # Save + snapshot v1 + grafo dei wikilink in transazione: o si crea la pagina completa, o niente.
      saved = ActiveRecord::Base.transaction do
        if page.save
          Knowledge::RecordVersion.call(page: page, author: @author)
          Knowledge::Links::Sync.call(page: page)
          true
        else
          raise ActiveRecord::Rollback
        end
      end

      unless saved
        return Result.err(AppError.new(page.errors.full_messages.to_sentence,
                                       code: "R422-KNOWLEDGE-001", details: page.errors.to_hash))
      end

      # Embedding post-commit (la live = HEAD). Una proposta in revisione NON si embedda: resta
      # fuori dalla ricerca comunque, e una nota che verrà scartata non deve costare una chiamata al
      # servizio né sporcare l'indice. L'enqueue arriva all'accettazione (Knowledge::Pages::Approve).
      Knowledge::EmbedPageJob.perform_later(page_id: page.id) unless in_review?
      Result.ok(page)
    end

    private

    # CYRA-298: il canale che propone (oggi la CLI) chiede esplicitamente la revisione. Chi scrive
    # dal web non passa il flag e la pagina nasce pubblicata, esattamente come prima.
    def in_review?
      ActiveModel::Type::Boolean.new.cast(@params[:in_review]).present?
    end

    def technical_body? = Knowledge::PlainLanguageCheck.call(text: @params[:body]).complex?

    def visible_scope
      @visible_scope ||= Authorization::VisibleScope.new(account: @author, organization: @organization)
    end

    def visible_projects = visible_scope.projects
    def visible_groups = visible_scope.groups
    def full_access? = visible_scope.unscoped?

    # Sanifica gli id richiesti allo scope visibile (anti-BOLA). [] se nessuno richiesto; nil se
    # anche uno solo è fuori dallo scope (l'intera create fallisce → R404, niente collegamento furtivo).
    def resolve_ids(requested, scope)
      ids = Array(requested).map(&:to_s).reject(&:blank?).uniq
      return [] if ids.empty?

      found = scope.where(id: ids).pluck(:id).map(&:to_s)
      return nil unless found.sort == ids.sort

      found
    end

    def err(code, key, status)
      Result.err(AppError.new(I18n.t("member.knowledge.errors.#{key}"), code: code, status: status))
    end
  end
end
