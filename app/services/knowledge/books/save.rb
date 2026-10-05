# frozen_string_literal: true

module Knowledge
  module Books
    # Upsert di un book KB (crea se nuovo, aggiorna se esistente) e riconcilia le sue pagine.
    # Progetti e gruppi sono risolti SCOPED alla visibilità dell'autore (anti-BOLA). Le pagine incluse
    # possono appartenere a qualunque progetto effettivo del book,
    # nell'ordine dei page_ids → book_id + position; quelle rimosse tornano libere (book_id nil).
    # Tutto in transazione: o si salva il book CON le sue pagine riconciliate, o niente.
    class Save < ApplicationService
      def initialize(book:, actor:, organization:, params:, page_ids: [])
        @book = book
        @actor = actor
        @organization = organization
        @params = params
        @page_ids = Array(page_ids).map(&:to_s).reject(&:blank?)
      end

      def call
        resolve_scope
        return @scope_error if @scope_error

        saved = ActiveRecord::Base.transaction do
          @book.assign_attributes(title: @params[:title], description: @params[:description],
                                  organization: @organization, created_by: (@book.created_by || @actor))
          @book.projects = @selected_projects
          @book.groups = @selected_groups
          if @book.save
            reconcile_pages
            true
          else
            raise ActiveRecord::Rollback
          end
        end

        unless saved
          return Result.err(AppError.new(@book.errors.full_messages.to_sentence,
                                         code: "R422-KNOWLEDGE-004", details: @book.errors.to_hash))
        end

        Result.ok(@book)
      end

      private

      def resolve_scope
        project_ids = requested_ids(:project_ids, :project_id)
        group_ids = requested_ids(:group_ids)
        @selected_projects = visible_projects.where(id: project_ids).with_attached_icon_image.to_a
        @selected_groups = visible_groups.where(id: group_ids).with_attached_icon_image.to_a
        return if @selected_projects.size == project_ids.size && @selected_groups.size == group_ids.size

        @scope_error = Result.err(AppError.new(I18n.t("member.knowledge.errors.project_not_found"),
                                               code: "R404-KNOWLEDGE-002", status: :not_found))
      end

      # Riconcilia le pagine del book: solo pagine DEL suo progetto (anti-BOLA), nell'ordine dei
      # page_ids. update_all è voluto (mutazione diretta di FK/position, nessun callback/validazione).
      def reconcile_pages
        effective = @book.effective_projects.select(:id)
        scoped = ::Knowledge::Page.where(
          "EXISTS (SELECT 1 FROM connections_page_projects pp " \
          "WHERE pp.page_id = knowledge_pages.id AND pp.project_id IN (:ids)) " \
          "OR EXISTS (SELECT 1 FROM connections_page_groups pg JOIN projects p ON p.group_id = pg.group_id " \
          "WHERE pg.page_id = knowledge_pages.id AND p.id IN (:ids))",
          ids: effective
        )
        final_ids = scoped.where(id: @page_ids).pluck(:id).map(&:to_s)
        # Preserva l'ordine dei page_ids, tiene solo le pagine del progetto (anti-BOLA), dedup difensivo.
        ordered = @page_ids.uniq.select { |id| final_ids.include?(id) }

        # Pagine non più incluse: staccate dal book anche quando il loro progetto è appena uscito
        # dallo scope. Limitare questa query allo scope nuovo lascerebbe book_id orfani.
        ::Knowledge::Page.where(book_id: @book.id).where.not(id: ordered).update_all(book_id: nil, position: 0)
        # Pagine incluse: un solo UPDATE con CASE evita una query per voce del TOC.
        return if ordered.empty?

        clauses = ([ "WHEN ? THEN ?" ] * ordered.length).join(" ")
        bindings = ordered.each_with_index.flat_map { |id, index| [ id, index ] }
        update_sql = ActiveRecord::Base.sanitize_sql_array(
          [ "book_id = ?, position = CASE id #{clauses} END", @book.id, *bindings ]
        )
        scoped.where(id: ordered).update_all(update_sql)
      end

      def visible_projects
        Authorization::VisibleScope.new(account: @actor, organization: @organization).projects
      end

      def visible_groups
        Authorization::VisibleScope.new(account: @actor, organization: @organization).groups
      end

      def requested_ids(collection_key, legacy_key = nil)
        unless @params.key?(collection_key) || (legacy_key && @params.key?(legacy_key))
          association = collection_key == :group_ids ? @book.groups : @book.projects
          return association.ids.map(&:to_s) if @book.persisted?
        end

        values = Array(@params[collection_key])
        values << @params[legacy_key] if legacy_key && @params[legacy_key].present?
        values.map(&:to_s).reject(&:blank?).uniq
      end
    end
  end
end
