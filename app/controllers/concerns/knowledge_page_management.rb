# frozen_string_literal: true

# Chi può GESTIRE una pagina della knowledge base (modificarla, eliminarla, allegarci file).
#
# Estratto da Member::Knowledge::PagesController quando gli allegati (CYRA-176) hanno introdotto un
# secondo controller che deve decidere allo stesso modo: due copie di una regola di autorizzazione
# divergono, e una divergenza qui è un buco di permessi silenzioso.
#
# La regola: l'autore è sempre padrone della propria pagina (pattern Ideas); sulle altrui serve il
# permesso su TUTTI i progetti effettivi (pattern Books) e vederli tutti. Se la pagina non ha progetti
# effettivi — org-wide, o collegata a un solo gruppo senza progetti — `all?` sarebbe vacuously true:
# lì la gestione da parte di un non-autore richiede accesso pieno (owner/god), non un permesso vuoto,
# altrimenti un qualsiasi membro del gruppo potrebbe modificare le pagine altrui.
module KnowledgePageManagement
  extend ActiveSupport::Concern

  private

  def page_manageable?(page, key)
    note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
    return false unless page_full_scope_access?(page)
    return true if page.authored_by?(Current.account)

    projects = page.effective_projects
    projects.any? ? projects.all? { |project| can?(key, scope: project) } : unscoped_page_access?
  end

  # Accesso pieno = owner/god: unico a poter gestire pagine altrui senza progetti effettivi.
  def unscoped_page_access?
    Authorization::VisibleScope.unscoped?(account: Current.account, organization: Current.organization)
  end

  # Vede TUTTI i progetti effettivi della pagina (le org-wide non ne hanno → sempre vero, ma solo i
  # full-access ci arrivano: le altre pagine org-wide danno già 404 nello scoping).
  def page_full_scope_access?(page)
    !page.effective_projects.where.not(id: visible.projects.select(:id)).exists?
  end
end
