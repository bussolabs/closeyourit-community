# frozen_string_literal: true

module Knowledge
  # Aggiorna una pagina KB (già scoped dal controller). Contenuto (title/kind/body/tech_spec/tags) e
  # scope (progetti/gruppi) sono aggiornabili; l'organizzazione NON cambia. Ad ogni modifica del testo
  # semantico (title/kind/body/tech_spec) congela uno snapshot (Knowledge::Version, in transazione) e
  # ri-embedda: la pagina resta la LIVE/HEAD, la nuova versione la rispecchia. Un edit no-op non crea
  # versioni. Assegna SOLO i campi presenti nei params: un update parziale (CLI) non azzera gli altri;
  # il form web manda l'intero set. Lo scope si tocca solo se il canale invia project_ids/group_ids;
  # svuotarlo del tutto (pagina org-wide) richiede accesso pieno (come alla creazione).
  #
  # CYRA-419 — chi scrive lo dichiara IL CANALE (`authored_by`: :human dal web, :agent da chi
  # propone; `author_origin`: nome dell'assistente, della skill o del canale). L'origine della pagina
  # cambia SOLO se il testo è stato riscritto davvero: vedi #rewritten_authorship.
  class UpdatePage < ApplicationService
    # Campi di testo su cui si misura la riscrittura: quello che la pagina DICE. Tag, tipo, progetti
    # e allegati restano fuori — spostare una pagina di progetto non la rende tua.
    REWRITABLE_TEXT_COLUMNS = %w[title body tech_spec].freeze

    def initialize(page:, params:, actor:, authored_by: nil, author_origin: nil)
      @page = page
      @params = params
      @actor = actor
      @authored_by = authored_by
      @author_origin = author_origin
    end

    def call
      scope_change = resolve_scope_change
      return scope_change if scope_change.is_a?(Result) # anti-BOLA / zero-scope negato

      # CYRA-764: il revisore automatico sul testo RISULTANTE (persistito + params: un update
      # parziale non manda tutti i campi), PRIMA della transazione. Solo tag o scope non lo chiamano.
      review = review_if_text_changes
      # Sul rifiuto le modifiche restano assegnate IN MEMORIA (non salvate): il form di modifica le
      # ripresenta a chi deve correggere, invece del testo di prima.
      if review.err? || review.value&.rejected?
        @page.assign_attributes(writable_attributes)
        return review.err? ? review : Knowledge::Review.rejection(review.value)
      end

      content_changed = false

      saved = ActiveRecord::Base.transaction do
        @page.assign_attributes(writable_attributes.merge(review_attributes(review.value)))
        # CYRA-768 — il testo è cambiato ed è ripassato dal revisore: il conto della rilettura
        # riparte da sé, anche se a riscrivere è stata una macchina. È la conferma «a vuoto» a
        # chiedere una persona (Knowledge::Pages::ConfirmReview), non la riscrittura. Il tipo è
        # quello NUOVO (già assegnato): una decisione diventata nota perde la scadenza, e viceversa.
        @page.review_after = Knowledge::ReviewSchedule.next_for(kind: @page.kind) if refresh_review_after?
        # Dopo l'assegnazione e PRIMA del save: la riscrittura si misura fra il testo persistito e
        # quello nuovo, e la nuova origine entra nello stesso UPDATE.
        authorship = rewritten_authorship
        @page.assign_attributes(authorship) if authorship
        if @page.save
          # Scope APPLICATO solo dopo un save valido: `projects=`/`groups=` su un record persistito
          # scrivono subito i join, quindi toccarli prima della validazione muterebbe lo scope anche
          # quando il contenuto è invalido (i join sono già pre-validati in resolve_scope_change).
          apply_scope(scope_change) if scope_change
          content_changed = (@page.saved_changes.keys & Knowledge::EmbeddingText::WATCHED_COLUMNS).any?
          Knowledge::RecordVersion.call(page: @page, author: @actor) if content_changed
          # I wikilink vivono SOLO nel corpo: titolo/kind/tecnico/tag non spostano il grafo.
          Knowledge::Links::Sync.call(page: @page) if @page.saved_changes.key?("body")
          true
        else
          raise ActiveRecord::Rollback
        end
      end

      unless saved
        return Result.err(AppError.new(@page.errors.full_messages.to_sentence,
                                       code: "R422-KNOWLEDGE-002", details: @page.errors.to_hash))
      end

      Knowledge::EmbedPageJob.perform_later(page_id: @page.id) if content_changed
      Result.ok(@page)
    end

    private

    # La data di rilettura si rifà solo quando il TESTO cambia su una pagina già pubblicata. Un
    # cambio di soli tag non è una rilettura; una proposta ancora in revisione non ha un conto da far
    # ripartire — glielo mette chi la accetta.
    def refresh_review_after? = @text_changed && @page.status_published?

    # CYRA-419 — la nuova origine da scrivere, o nil per lasciare quella che c'è.
    #
    # Il segno «scritta da un assistente» decade SOLO quando una persona riscrive il testo davvero:
    # la soglia è Knowledge::SubstantiveEdit (correggere una virgola non rende tua la pagina, e
    # cambiare tag, tipo o progetti nemmeno — non toccano il testo). Vale simmetricamente: un
    # assistente che riscrive la pagina di una persona la marca come propria, altrimenti il testo
    # generato resterebbe sotto la firma di chi lo aveva scritto a mano.
    #
    # Un canale che non dichiara chi scrive non tocca niente: ripristinare una versione precedente
    # (Knowledge::RestoreVersion) rimette un testo già esistente, non lo scrive.
    def rewritten_authorship
      return nil if @authored_by.blank?
      return nil unless Knowledge::SubstantiveEdit.call(before: previous_text, after: current_text)

      Knowledge::Page.authorship_attributes(kind: @authored_by, origin: @author_origin)
    end

    # Testo persistito e testo nuovo: valutati DOPO assign_attributes, quando `*_was` è ancora il
    # valore che sta nel database.
    def previous_text = REWRITABLE_TEXT_COLUMNS.map { |column| @page.public_send(:"#{column}_was") }.join("\n")
    def current_text = REWRITABLE_TEXT_COLUMNS.map { |column| @page.public_send(column) }.join("\n")

    # Il testo che la pagina AVRÀ, e il revisore su di esso — solo se una colonna del significato
    # (title/kind/body/tech_spec) cambia davvero. Result.ok(nil) quando non c'è niente da giudicare.
    def review_if_text_changes
      next_text = @page.attributes.slice(*Knowledge::EmbeddingText::WATCHED_COLUMNS)
                       .merge(writable_attributes.stringify_keys.slice(*Knowledge::EmbeddingText::WATCHED_COLUMNS))
      current = @page.attributes.slice(*Knowledge::EmbeddingText::WATCHED_COLUMNS)
      @text_changed = next_text.transform_values(&:to_s) != current.transform_values(&:to_s)
      tags_changed = writable_attributes.key?(:tags) && writable_attributes[:tags] != @page.tags
      return Result.ok(nil) unless @text_changed || tags_changed

      # Solo i tag: le regole meccaniche (K11) senza pagare il modello — togliere i tag a una pagina
      # accettata non deve aggirare il gate.
      Knowledge::ReviewPage.call(title: next_text["title"], body: next_text["body"], tech_spec: next_text["tech_spec"],
                                 kind: next_text["kind"], tags: writable_attributes.fetch(:tags, @page.tags),
                                 scope: Knowledge::Review.scope_for(account: @actor, organization: @page.organization),
                                 exclude_page_id: @page.id, precheck_only: !@text_changed)
    end

    # Il verdetto si scrive (o si azzera, revisore spento) SOLO quando il testo cambia: un cambio di
    # soli tag passato dal pre-check non deve cancellare il verdetto sul testo che resta lo stesso.
    def review_attributes(verdict)
      @text_changed ? Knowledge::Review.page_attributes(verdict) : {}
    end

    # Indifferent access: il canale web passa ActionController::Parameters, RestoreVersion un Hash a simboli.
    def source
      @source ||= (@params.respond_to?(:to_unsafe_h) ? @params.to_unsafe_h : @params.to_h).with_indifferent_access
    end

    # Solo le chiavi effettivamente presenti vengono scritte; kind vuoto mantiene il corrente.
    def writable_attributes
      attrs = {}
      attrs[:title] = source[:title] if source.key?(:title)
      attrs[:body] = source[:body] if source.key?(:body)
      attrs[:tech_spec] = source[:tech_spec] if source.key?(:tech_spec)
      attrs[:tags] = source[:tags] if source.key?(:tags)
      attrs[:kind] = source[:kind].presence || @page.kind if source.key?(:kind)
      attrs
    end

    # {projects:, groups:} (relation; nil = lato non toccato) da assegnare in transazione. Result se
    # un id è fuori dalla visibilità dell'attore (R404) o se lo scope risultante è vuoto senza pieno
    # accesso (R403). Gestisce l'update parziale: lo stato "finale" di un lato non toccato = l'attuale.
    def resolve_scope_change
      touches_projects = source.key?(:project_ids)
      touches_groups = source.key?(:group_ids)
      return nil unless touches_projects || touches_groups

      if touches_projects
        project_ids = resolve_ids(source[:project_ids], visible_projects)
        return not_found if project_ids.nil?

        projects = Projects::Project.where(id: project_ids).with_attached_icon_image
      end
      if touches_groups
        group_ids = resolve_ids(source[:group_ids], visible_groups)
        return not_found if group_ids.nil?

        groups = Projects::Group.where(id: group_ids).with_attached_icon_image
      end

      if (projects || @page.projects).empty? && (groups || @page.groups).empty? && !full_access?
        return err("R403-KNOWLEDGE-001", :scope_required, :forbidden)
      end

      permission_error = scope_permission_error(projects, groups)
      return permission_error if permission_error

      { projects: projects, groups: groups }
    end

    # Collegare NUOVI progetti/gruppi a una pagina NON propria richiede knowledge.edit su ciascun
    # progetto effettivo aggiunto E su ciascun gruppo aggiunto (o full-access): impedisce di spingere
    # una pagina altrui dove non si gestisce. L'autore resta padrone della propria pagina.
    def scope_permission_error(projects, groups)
      return nil if full_access? || @page.authored_by?(@actor)

      final_project_ids = projects ? projects.ids : @page.projects.ids
      final_group_ids = groups ? groups.ids : @page.groups.ids

      added_projects_error(final_project_ids, final_group_ids) || added_groups_error(final_group_ids)
    end

    # Progetti effettivi AGGIUNTI (diretti + dei gruppi): serve knowledge.edit su ciascuno.
    def added_projects_error(final_project_ids, final_group_ids)
      added = effective_project_ids(final_project_ids, final_group_ids) - @page.effective_projects.ids
      return nil if added.empty?

      addable = Projects::Project.where(id: added)
      return nil if addable.all? { |project| authorization.can?("knowledge.edit", scope: project) }

      err("R403-KNOWLEDGE-002", :scope_forbidden, :forbidden)
    end

    # GRUPPI aggiunti: un gruppo allarga lo scope ai suoi progetti FUTURI, quindi va autorizzato sul
    # gruppo stesso — anche quando oggi è VUOTO e non produce alcun progetto effettivo su cui valutare
    # can?. Senza questo, una pagina altrui finisce in un gruppo non gestito appena riceve un progetto
    # (CYRA-177).
    def added_groups_error(final_group_ids)
      added = final_group_ids - @page.groups.ids
      return nil if added.empty?

      addable = Projects::Group.where(id: added)
      return nil if addable.all? { |group| authorization.can_group?("knowledge.edit", group) }

      err("R403-KNOWLEDGE-002", :scope_forbidden, :forbidden)
    end

    # Progetti effettivi = diretti + quelli dei gruppi (anche futuri). Gemello di Page#effective_projects
    # ma calcolato dagli id in memoria (lo stato nuovo non è ancora persistito quando lo valutiamo).
    def effective_project_ids(project_ids, group_ids)
      from_groups = group_ids.empty? ? [] : Projects::Project.where(group_id: group_ids).ids
      (project_ids + from_groups).uniq
    end

    def authorization
      @authorization ||= Authorization::Resolver.new(account: @actor, organization: @page.organization)
    end

    def apply_scope(change)
      @page.projects = change[:projects] if change[:projects]
      @page.groups = change[:groups] if change[:groups]
    end

    def visible_scope
      @visible_scope ||= Authorization::VisibleScope.new(account: @actor, organization: @page.organization)
    end

    def visible_projects = visible_scope.projects
    def visible_groups = visible_scope.groups
    def full_access? = visible_scope.unscoped?

    # Sanifica gli id allo scope visibile (anti-BOLA). [] se nessuno; nil se anche uno è fuori scope.
    def resolve_ids(requested, scope)
      ids = Array(requested).map(&:to_s).reject(&:blank?).uniq
      return [] if ids.empty?

      found = scope.where(id: ids).pluck(:id).map(&:to_s)
      return nil unless found.sort == ids.sort

      found
    end

    def not_found = err("R404-KNOWLEDGE-001", :project_not_found, :not_found)

    def err(code, key, status)
      Result.err(AppError.new(I18n.t("member.knowledge.errors.#{key}"), code: code, status: status))
    end
  end
end
