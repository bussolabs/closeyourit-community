# frozen_string_literal: true

module Knowledge
  module Pages
    # Upsert atomico di una fonte versionata nella Knowledge. La publication_key è l'identità stabile
    # NELL'ORGANIZZAZIONE (non più nel singolo progetto): la stessa chiave pubblicata da progetti
    # diversi CONVERGE su UNA pagina, a cui si aggiunge il progetto della route. In assenza di binding
    # adotta una pagina legacy (senza chiave) del PROGETTO della route solo se il titolo ha un singolo
    # match. Row lock + indice DB impediscono doppioni sotto retry e publish concorrenti.
    class Publish < ApplicationService
      PUBLICATION_IDENTITY_INDEX = "index_knowledge_pages_publication_identity"
      Outcome = Data.define(:page, :operation, :adopted_legacy, :content_changed)

      def initialize(project:, actor:, publication_key:, params:)
        @project = project
        @actor = actor
        @publication_key = publication_key.to_s
        @params = params
        @normalized_title = params[:title].to_s.strip
      end

      def call
        return invalid_publication_key unless @publication_key.match?(Knowledge::Page::PUBLICATION_KEY_FORMAT)
        return invalid_kind unless valid_kind?

        # CYRA-764: il revisore automatico PRIMA della transazione — mai una chiamata di rete con un
        # row lock in mano. Gira anche quando il contenuto risulterà identico: aprire la transazione
        # due volte per risparmiarlo costerebbe di più.
        review = ::Knowledge::ReviewPage.call(title: @params[:title], body: @params[:body], tech_spec: nil,
                                              kind: @params[:kind].presence || :note, tags: @params[:tags],
                                              scope: ::Knowledge::Review.scope_for(account: @actor, organization: @project.organization),
                                              exclude_page_id: org_pages.find_by(publication_key: @publication_key)&.id)
        return review if review.err?
        return ::Knowledge::Review.rejection(review.value) if review.value&.rejected?

        @review_attributes = ::Knowledge::Review.page_attributes(review.value)

        outcome = ApplicationRecord.transaction do
          pages = org_pages
          page = pages.find_by(publication_key: @publication_key)

          if page
            converge(page)
          else
            publish_unbound(pages)
          end
        end
        finish(outcome)
      rescue ActiveRecord::RecordNotUnique => e
        raise unless publication_identity_conflict?(e)

        finish(recover_publication_identity)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(
          AppError.new(
            e.record.errors.full_messages.to_sentence,
            code: "R422-KNOWLEDGE-005",
            details: e.record.errors.to_hash
          )
        )
      end

      private

      def org_pages
        Knowledge::Page.where(organization_id: @project.organization_id)
      end

      # Convergenza su una pagina ESISTENTE trovata per publication_key: ammessa SOLO se l'attore la
      # può già gestire (autore o knowledge.edit sull'intero scope visibile). Il lookup è org-wide per
      # rispettare l'identità unica della chiave, ma senza questo gate chi conosce la chiave giusta
      # sovrascriverebbe — e si renderebbe leggibile via link_project — una pagina collegata solo a
      # progetti che non vede. La convergenza VOLUTA tra progetti propri resta intatta (CYRA-177).
      # Il gate gira DOPO il row lock: la gestibilità si valuta sullo stato serializzato, non su uno
      # scope che un writer concorrente potrebbe allargare tra controllo e scrittura (TOCTOU).
      def converge(page)
        page.lock!
        return forbidden_overwrite unless Knowledge::PageManageable.call(page:, actor: @actor)

        update_page(page, adopted_legacy: false)
      end

      def forbidden_overwrite
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.publication_forbidden"),
            code: "R403-KNOWLEDGE-003",
            status: :forbidden
          )
        )
      end

      # La pubblicazione da un progetto AGGIUNGE quel progetto ai collegamenti della pagina: la stessa
      # publication_key pubblicata da più progetti dell'org converge su UNA pagina condivisa.
      def link_project(page)
        page.projects << @project unless page.projects.include?(@project)
      end

      def finish(outcome)
        return outcome if outcome.is_a?(Result)

        Knowledge::EmbedPageJob.perform_later(page_id: outcome.page.id) if outcome.content_changed
        Result.ok(outcome)
      end

      # Il vincolo può vincere mentre un altro writer sta adottando una legacy. L'eccezione arriva
      # dopo il rollback della prima transazione: una nuova transazione rilegge la sola identità
      # vincente, la blocca e applica deterministicamente il writer che ha perso il race.
      def recover_publication_identity
        ApplicationRecord.transaction do
          converge(org_pages.find_by!(publication_key: @publication_key))
        end
      end

      def publication_identity_conflict?(error)
        cause = error.cause
        return false unless cause.respond_to?(:result)

        cause.result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == PUBLICATION_IDENTITY_INDEX
      end

      # Legacy = pagine senza publication_key del PROGETTO della route (non di tutta l'org): la
      # pubblicazione non deve adottare per titolo una pagina di un altro progetto.
      def publish_unbound(pages)
        legacy = pages.where(publication_key: nil)
                      .where("LOWER(BTRIM(knowledge_pages.title)) = LOWER(?)", @normalized_title)
                      .where("EXISTS (SELECT 1 FROM connections_page_projects pp " \
                             "WHERE pp.page_id = knowledge_pages.id AND pp.project_id = ?)", @project.id)
                      .order(:id).limit(2).lock.to_a
        return ambiguous_legacy if legacy.many?
        return adopt_legacy(legacy.sole) if legacy.one?

        create_or_update(pages)
      end

      # La legacy è ancorata al progetto sorgente (filtro pp.project_id), ma può estendersi ad altri
      # scope che l'attore non vede/gestisce: come la convergenza, l'adozione esige che l'attore possa
      # gestire l'INTERA pagina, non solo il progetto della route (CYRA-177). La riga è già lockata da
      # publish_unbound (.lock), quindi il gate gira sullo stato serializzato.
      def adopt_legacy(page)
        return forbidden_overwrite unless Knowledge::PageManageable.call(page:, actor: @actor)

        page.publication_key = @publication_key
        update_page(page, adopted_legacy: true)
      end

      # `create_or_find_by!` usa un savepoint e il vincolo DB come autorità: se due richieste con
      # lookup stantio inseriscono insieme, il perdente rilegge la riga vincente e la aggiorna.
      def create_or_update(pages)
        attributes = content_attributes
        page = pages.create_or_find_by!(publication_key: @publication_key) do |candidate|
          # CYRA-768: la pagina nasce già pubblicata, quindi il conto della rilettura parte da qui —
          # come in Knowledge::CreatePage. Senza, tutto ciò che entra da un repo versionato (cioè il
          # grosso del parco) resterebbe vero per sempre.
          candidate.assign_attributes(
            attributes.merge(created_by: @actor, organization: @project.organization,
                             review_after: Knowledge::ReviewSchedule.next_for(kind: attributes[:kind]))
          )
        end
        created = page.previously_new_record?

        if created
          link_project(page)
          Knowledge::RecordVersion.call(page:, author: @actor)
          Knowledge::Links::Sync.call(page:)
          Outcome.new(page:, operation: "created", adopted_legacy: false, content_changed: true)
        else
          converge(page)
        end
      end

      def update_page(page, adopted_legacy:)
        page.assign_attributes(content_attributes(page))
        # CYRA-768 — il conto riparte SOLO se la pubblicazione porta un testo davvero diverso, come
        # in Knowledge::UpdatePage. `cyi kb publish` ripassa sull'intero repo: rinnovare la data a
        # ogni giro vorrebbe dire che nessuna pagina scade mai e la coda resta vuota per sempre.
        # Prima del save, quando `changed` è ancora la differenza col testo persistito.
        if (page.changed & Knowledge::EmbeddingText::WATCHED_COLUMNS).any?
          page.review_after = Knowledge::ReviewSchedule.next_for(kind: page.kind)
        end
        page.save!
        link_project(page)
        changed = (page.saved_changes.keys & Knowledge::EmbeddingText::WATCHED_COLUMNS).any?
        Knowledge::RecordVersion.call(page:, author: @actor) if changed
        # I wikilink vivono SOLO nel corpo: titolo/kind non spostano il grafo.
        Knowledge::Links::Sync.call(page:) if page.saved_changes.key?("body")

        Outcome.new(page:, operation: "updated", adopted_legacy:, content_changed: changed)
      end

      def content_attributes(page = nil)
        attributes = {
          title: @params[:title],
          body: @params[:body],
          kind: @params[:kind].presence || page&.kind || :note
        }
        attributes[:tags] = @params[:tags] if @params.key?(:tags)
        attributes.merge(@review_attributes || {})
      end

      def ambiguous_legacy
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.publication_ambiguous", title: @normalized_title),
            code: "R409-KNOWLEDGE-001",
            status: :conflict,
            details: { title: @normalized_title, legacy_matches: 2 }
          )
        )
      end

      def invalid_publication_key
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.publication_key_invalid"),
            code: "R422-KNOWLEDGE-005",
            details: { publication_key: [ I18n.t("errors.messages.invalid") ] }
          )
        )
      end

      def valid_kind?
        @params[:kind].blank? || Knowledge::Page.kinds.key?(@params[:kind].to_s)
      end

      def invalid_kind
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.publication_kind_invalid"),
            code: "R422-KNOWLEDGE-005",
            details: { kind: [ I18n.t("errors.messages.inclusion") ] }
          )
        )
      end
    end
  end
end
