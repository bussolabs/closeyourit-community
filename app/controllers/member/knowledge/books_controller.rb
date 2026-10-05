# frozen_string_literal: true

module Member
  module Knowledge
    # Book KB = collezioni ordinate di pagine (vista Outline: indice a sinistra, contenuto a destra).
    # Leggere e creare = baseline di chi vede lo scope (come le pagine e i ticket); gestire book
    # ALTRUI è gated (knowledge.edit/delete, pattern pagine). Model SEMPRE fully-qualified
    # ::Knowledge::* (anti-shadowing, come Member::Knowledge::PagesController).
    class BooksController < Member::BaseController
      permission_not_required "Leggere e creare un book è baseline di chi vede lo scope; gestire quelli altrui è " \
                              "gated più sotto.",
                              only: %i[index show new create]

      before_action :set_book, only: %i[show edit update destroy]
      before_action :require_manage_permission, only: %i[edit update destroy]
      before_action :load_form_options, only: %i[new create edit update]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :project_id, :q, :sort, only: :index

      # CYRA-924 — every column sorts but Projects, which holds several values (C9).
      SORT_COLUMNS = {
        "title" => "LOWER(knowledge_books.title)",
        "pages" => "(SELECT COUNT(*) FROM knowledge_pages WHERE knowledge_pages.book_id = knowledge_books.id)",
        "author" => "(SELECT LOWER(accounts.name) FROM accounts WHERE accounts.id = knowledge_books.created_by_id)",
        "updated" => :updated_at
      }.freeze

      def index
        scope = sorted(visible_books.includes(:projects, { groups: :projects }, :created_by).ordered, columns: SORT_COLUMNS)
        scope = books_for_projects(scope, filter_ids(:project_id)) if filter_ids(:project_id).any?
        scope = scope.where("knowledge_books.title ILIKE ?", "%#{search_q}%") if search_q.present?
        @pagination = paginate(scope)
        @books = @pagination.records
        # Conteggio pagine per book in UNA query (no N+1 su book.pages.size nella tabella).
        @page_counts = ::Knowledge::Page.where(book_id: @books.map(&:id),
                                               id: visible.pages.select(:id))
                                         .group(:book_id).count
        @filter_projects = visible.projects.order(:name)
        @visible_project_ids = @filter_projects.map(&:id).to_set
        # CYRA-555 — «nessuna raccolta» resta il messaggio di chi non ne ha nessuna: a ricerca o
        # filtro attivi si dice invece che nessuna corrisponde, col totale vero accanto.
        @filtering = search_q.present? || filter_ids(:project_id).any?
        @total_books = visible_books.count
      end

      def show
        @pages = @book.pages.where(id: visible.pages.select(:id)).includes(:projects)
        # Pagina attiva = quella indicata da page_id (se nel book), altrimenti la prima del TOC.
        @active_page = @pages.detect { |page| page.id == params[:page_id] } || @pages.first
        # Wikilink cliccabili SOLO verso pagine che il lettore può aprire (vedi Links::Render).
        @active_page_links = @active_page&.links
                                         &.where(related_id: visible_pages.select(:id))
                                         &.includes(:related)
        @can_edit = manageable?("knowledge.edit")
        @can_delete = manageable?("knowledge.delete")
        @visible_projects = @book.effective_projects.where(id: visible.projects.select(:id)).order(:name)
        @visible_groups = @book.groups.where(id: visible.groups.select(:id)).order(:name)
      end

      def new
        @book = ::Knowledge::Book.new(organization: Current.organization, created_by: Current.account)
        @book.project = visible.projects.find_by(id: params[:project_id]) if params[:project_id].present?
      end

      def create
        result = ::Knowledge::Books::Save.call(
          book: ::Knowledge::Book.new, actor: Current.account, organization: Current.organization,
          params: book_params, page_ids: params[:page_ids]
        )
        if result.ok?
          redirect_to member_knowledge_book_path(result.value), notice: t("member.knowledge.books.created")
        else
          @book = ::Knowledge::Book.new(title: book_params[:title], description: book_params[:description],
                                        organization: Current.organization, created_by: Current.account)
          selected_project_ids = Array(book_params[:project_ids]).map(&:to_s)
          selected_group_ids = Array(book_params[:group_ids]).map(&:to_s)
          @book.projects = @projects.select { |project| selected_project_ids.include?(project.id.to_s) }
          @book.groups = @groups.select { |group| selected_group_ids.include?(group.id.to_s) }
          @errors = result.error.details || {}
          flash.now[:alert] = result.error.message
          render :new, status: :unprocessable_content
        end
      end

      def edit
        @book_pages = visible_book_pages
      end

      def update
        result = ::Knowledge::Books::Save.call(
          book: @book, actor: Current.account, organization: Current.organization,
          params: book_params, page_ids: params[:page_ids]
        )
        if result.ok?
          redirect_to member_knowledge_book_path(@book), notice: t("member.knowledge.books.updated")
        else
          @book_pages = visible_book_pages
          @errors = result.error.details || {}
          flash.now[:alert] = result.error.message
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        @book.destroy
        redirect_to member_knowledge_books_path, notice: t("member.knowledge.books.deleted")
      end

      private

      # Anti-BOLA + scoping: book di un progetto non visibile → RecordNotFound.
      def set_book
        @book = visible_books.find(params[:id])
      end

      def visible_books
        ::Knowledge::Book.where(organization_id: Current.organization.id)
                         .visible_within(visible.projects.select(:id))
      end

      # L'autore gestisce sempre i propri book; sui altrui decide la chiave RBAC.
      def manageable?(key)
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        full_scope_access? && (@book.authored_by?(Current.account) ||
          @book.effective_projects.all? { |project| can?(key, scope: project) })
      end

      def require_manage_permission
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        return if full_scope_access? && @book.authored_by?(Current.account)

        key = action_name == "destroy" ? "knowledge.delete" : "knowledge.edit"
        allowed = full_scope_access? && @book.effective_projects.all? { |project| can?(key, scope: project) }
        redirect_to root_path, alert: t("member.authorization.forbidden") unless allowed
      end

      def load_form_options
        @projects = visible.projects.order(:name)
        @groups = visible.groups.order(:name)
        # Anti-leak: etichetta le pagine candidate col primo progetto VISIBILE, non trapelare scope nascosti.
        @visible_project_ids = @projects.map(&:id).to_set
      end

      def book_params
        params.permit(:project_id, :title, :description, project_ids: [], group_ids: [])
      end

      def visible_pages
        visible.pages
      end

      def visible_book_pages
        effective = @book.effective_projects.select(:id)
        ::Knowledge::Page.where(id: visible.pages.select(:id))
             .where("EXISTS (SELECT 1 FROM connections_page_projects pp " \
                    "WHERE pp.page_id = knowledge_pages.id AND pp.project_id IN (:ids)) " \
                    "OR EXISTS (SELECT 1 FROM connections_page_groups pg JOIN projects p ON p.group_id = pg.group_id " \
                    "WHERE pg.page_id = knowledge_pages.id AND p.id IN (:ids))", ids: effective)
             .includes(:projects).order(:title)
      end

      def full_scope_access?
        !@book.effective_projects.where.not(id: visible.projects.select(:id)).exists?
      end

      def books_for_projects(scope, ids)
        scope.visible_within(ids)
      end
    end
  end
end
