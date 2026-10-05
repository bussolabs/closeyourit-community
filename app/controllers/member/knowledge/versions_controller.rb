# frozen_string_literal: true

module Member
  module Knowledge
    # Cronologia delle versioni di una pagina KB (sola lettura) + ripristino di una versione come
    # nuova live. Consultare = stessa visibilità del vedere la pagina (nessun gate oltre lo scoping
    # anti-BOLA); ripristinare = gate come l'edit (autore o knowledge.edit su tutti i progetti
    # effettivi). Model SEMPRE fully-qualified ::Knowledge::* (anti-shadowing).
    class VersionsController < Member::BaseController
      permission_not_required "Cronologia di una pagina visibile: sola lettura, il ripristino è gated più sotto.",
                              only: %i[index show]

      before_action :set_page
      before_action :set_version, only: %i[show restore]
      before_action :require_manage_permission, only: :restore

      def index
        # CYRA-684 — lo storico cresce a ogni salvataggio: a pagine, non tutto in una volta.
        @live_number = @page.current_version_number
        @pagination = paginate(sorted(@page.versions.reorder(number: :desc), columns: sort_columns))
        @versions = @pagination.records
        @can_edit = manageable?("knowledge.edit")
      end

      def show
        @live_number = @page.current_version_number
        @is_live = @version.number == @live_number
        @can_edit = manageable?("knowledge.edit")
      end

      def restore
        result = ::Knowledge::RestoreVersion.call(page: @page, version: @version, actor: Current.account)
        if result.ok?
          redirect_to member_knowledge_page_path(@page), notice: t("member.knowledge.versions.restored")
        else
          redirect_to member_knowledge_page_version_path(@page, @version), alert: result.error.message
        end
      end

      private

      # CYRA-924 — every column but restore sorts (C9); the live version is the one "in use".
      def sort_columns
        {
          "number" => :number,
          "author" => "LOWER(knowledge_versions.author_name)",
          "date" => :created_at,
          "status" => "(knowledge_versions.number = #{@live_number.to_i})"
        }
      end

      # Anti-BOLA: pagina non visibile → RecordNotFound.
      def set_page
        @page = visible.pages.find(params[:page_id])
      end

      # Scoping su @page: una versione di un'altra pagina → RecordNotFound.
      def set_version
        @version = @page.versions.find_by!(number: params[:id])
      end

      # L'autore gestisce sempre le proprie pagine; sulle altrui serve il permesso su TUTTI i progetti
      # effettivi (pattern Books) e vederli tutti. Pagina senza progetti effettivi (org-wide o solo su
      # un gruppo senza progetti) → `all?` sarebbe vacuously true: il ripristino da parte di un
      # non-autore richiede accesso pieno (owner/god), non un permesso vuoto.
      def manageable?(key)
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        return false unless full_scope_access?
        return true if @page.authored_by?(Current.account)

        projects = @page.effective_projects
        projects.any? ? projects.all? { |project| can?(key, scope: project) } : full_access?
      end

      def require_manage_permission
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        return if full_scope_access? && @page.authored_by?(Current.account)

        projects = @page.effective_projects
        gate = projects.any? ? projects.all? { |project| can?("knowledge.edit", scope: project) } : full_access?
        redirect_to root_path, alert: t("member.authorization.forbidden") unless full_scope_access? && gate
      end

      def full_access?
        Authorization::VisibleScope.unscoped?(account: Current.account, organization: Current.organization)
      end

      def full_scope_access?
        !@page.effective_projects.where.not(id: visible.projects.select(:id)).exists?
      end
    end
  end
end
