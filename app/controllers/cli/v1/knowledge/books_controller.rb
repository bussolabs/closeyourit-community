# frozen_string_literal: true

module Cli
  module V1
    module Knowledge
      # Book KB per la CLI (`cyi kb books`): collezioni ordinate di pagine dei progetti visibili
      # all'account del token. Leggere (list/show) = baseline dello scope. Aggiungere una pagina al
      # TOC (add-page) è una modifica del book → stessa policy del canale Member: chi agisce deve
      # vedere l'INTERO scope del book (nessun progetto fuori vista) ed esserne l'autore o avere
      # knowledge.edit su tutti i suoi progetti. Model SEMPRE fully-qualified ::Knowledge::*
      # (anti-shadowing). Riordino nel service Knowledge::Books::AddPage (rules/backend-channels.md).
      class BooksController < Cli::V1::BaseController
        before_action :set_book, only: %i[show add_page]
        before_action :set_page, only: :add_page
        before_action :authorize_add_page!, only: :add_page

        # Filtri: ?project (key o UUID, 404 fuori scope) e ?q (titolo ILIKE). Il conteggio pagine è
        # scoped alle pagine dei progetti visibili (come l'index web), in una sola query.
        def index
          scope = visible_books.includes(:projects, :groups, :created_by).ordered
          if params[:project].present?
            project = resolve_project(params[:project])
            return not_found_project if project.nil?

            scope = scope.visible_within([ project.id ])
          end
          query = params[:q].to_s.strip
          scope = scope.where("knowledge_books.title ILIKE ?", "%#{query}%") if query.present?
          records, meta = paginate(scope)
          counts = page_counts(records)
          render_ok(records.map { |book| book_summary(book, pages_count: counts[book.id] || 0) }, meta: meta)
        end

        # Book col sommario (TOC) aggiornato: la risposta canonica di show e add-page.
        def show
          render_ok(book_with_toc(@book))
        end

        def add_page
          result = ::Knowledge::Books::AddPage.call(book: @book, page: @page, position: params[:position])
          if result.ok?
            render_ok(book_with_toc(@book))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        # Anti-BOLA: book risolto tra quelli visibili (progetto/gruppo fuori scope → R404).
        def set_book
          @book = visible_books.find(params[:id])
        end

        # Anti-BOLA: pagina risolta tra quelle dei progetti visibili (fuori scope/assente → R404).
        def set_page
          @page = visible_pages.find(params[:page_id])
        end

        # Gate di modifica del book, allineato al canale Member (require_manage_permission): serve il
        # PIENO accesso allo scope — così l'add-page non riordina mai pagine di progetti non visibili.
        def authorize_add_page!
          return true if book_manageable?(@book)

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        def book_manageable?(book)
          return false unless full_scope_access?(book)

          book.authored_by?(Current.account) ||
            book.effective_projects.all? { |project| authorization.can?("knowledge.edit", scope: project) }
        end

        # Vero solo se OGNI progetto effettivo del book è visibile all'account (nessuna pagina fuori vista).
        def full_scope_access?(book)
          !book.effective_projects.where.not(id: visible_projects.select(:id)).exists?
        end

        def visible_books
          ::Knowledge::Book.where(organization_id: Current.organization.id)
                           .visible_within(visible_projects.select(:id))
        end

        # CYRA-174 ha tolto knowledge_pages.project_id: la visibilita' passa dalle join N:N.
        # Stesso scope di Cli::V1::Knowledge::Pages — unica fonte di verita' per "pagine che vedo".
        def visible_pages
          ::Knowledge::Page.visible_to(account: Current.account, organization: Current.organization,
                                       visible_project_ids: visible_projects.select(:id),
                                       visible_group_ids: visible_groups.select(:id))
        end

        # Riferimento progetto CLI-friendly: key umana (case-insensitive) o UUID, dentro lo scope.
        def resolve_project(ref)
          ref = ref.to_s.strip
          return nil if ref.blank?

          visible_projects.find_by(key: ref.upcase) || visible_projects.find_by(id: ref)
        end

        def page_counts(books)
          visible_pages.where(book_id: books.map(&:id)).group(:book_id).count
        end

        # Metadati + progetti/gruppi SCOPED alla visibilità del lettore: un book multi-progetto non
        # svela mai key di progetti o nomi di gruppi che l'account non vede (anti-leak).
        def book_summary(book, pages_count:)
          KnowledgeBookSerializer.new(book).as_json.merge(
            "projects" => visible_records(book.projects, visible_project_ids).map(&:key),
            "groups" => visible_records(book.groups, visible_group_ids).map(&:name),
            "pages_count" => pages_count
          )
        end

        # Sommario (TOC) scoped alle pagine dei progetti visibili al lettore: un book multi-progetto
        # non svela mai i titoli delle pagine dei progetti che l'account non vede (anti-leak).
        def book_with_toc(book)
          toc = book.pages.where(id: visible_pages.select(:id)).includes(:projects).to_a
          # I visible_*_ids servono al serializer per esporre, di ogni riga, solo un progetto che il
          # lettore vede davvero: le righe sono già scopate, ma una pagina multi-progetto potrebbe
          # comunque mostrare la key di un progetto nascosto.
          pages = KnowledgeBookPageSerializer.new(toc, params: scope_params).as_json
          book_summary(book, pages_count: toc.size).merge("pages" => pages)
        end

        def visible_records(records, ids)
          records.select { |record| ids.include?(record.id) }
        end

        # Forma attesa da KnowledgePageSerializer.visible_projects/_groups, riusata dal serializer
        # del TOC (stesso contratto di Cli::V1::Knowledge::Pages#visible_scope_params).
        def scope_params
          { visible_project_ids: visible_project_ids, visible_group_ids: visible_group_ids }
        end

        def visible_project_ids
          @visible_project_ids ||= visible_projects.pluck(:id).to_set
        end

        def visible_group_ids
          @visible_group_ids ||= visible_groups.pluck(:id).to_set
        end

        def not_found_project
          render_error("R404-KNOWLEDGE-001", I18n.t("member.knowledge.errors.project_not_found"),
                       status: :not_found)
        end
      end
    end
  end
end
