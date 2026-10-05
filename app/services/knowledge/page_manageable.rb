# frozen_string_literal: true

module Knowledge
  # Chi può GESTIRE una pagina KB (sovrascriverne il contenuto, allargarne lo scope) lato SERVICE,
  # con l'account REALE dell'attore. Gemello di KnowledgePageManagement#page_manageable? (il gate dei
  # controller): stessa regola, ma senza l'impersonation god via true_account, che vive solo nel web.
  #
  # La regola: l'autore è padrone della propria pagina; sulle altrui serve vedere TUTTI i progetti
  # effettivi e avere `knowledge.edit` su ciascuno. Se la pagina non ha progetti effettivi — org-wide
  # o collegata solo a gruppi vuoti — un non-autore la gestisce solo con accesso pieno (owner/god),
  # mai con un `all?` vacuously true (altrimenti chiunque veda un gruppo modificherebbe pagine altrui).
  class PageManageable < ApplicationService
    def initialize(page:, actor:, permission: "knowledge.edit")
      @page = page
      @actor = actor
      @permission = permission
    end

    def call
      return false unless sees_all_effective_projects?
      return true if @page.authored_by?(@actor)

      projects = @page.effective_projects
      projects.any? ? projects.all? { |project| resolver.can?(@permission, scope: project) } : full_access?
    end

    private

    # Vede TUTTI i progetti effettivi della pagina (le org-wide non ne hanno → vacuously vero).
    def sees_all_effective_projects?
      !@page.effective_projects.where.not(id: visible_scope.projects.select(:id)).exists?
    end

    def full_access? = visible_scope.unscoped?

    def resolver
      @resolver ||= Authorization::Resolver.new(account: @actor, organization: @page.organization)
    end

    def visible_scope
      @visible_scope ||= Authorization::VisibleScope.new(account: @actor, organization: @page.organization)
    end
  end
end
