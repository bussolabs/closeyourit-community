# frozen_string_literal: true

# In quale organizzazione si trova chi sta guardando, e se può restarci. Risolve Current.organization
# dalla sessione: per i non-god validata contro le membership dell'account (anti-BOLA, fallback prima
# membership); per il god qualsiasi org (cross-tenant nativo, gated su true_account.god? — allora
# @current_membership può essere nil).
#
# CYRA-740 — qui c'erano anche i permessi (PermissionGates), gli elenchi visibili di ogni dominio
# (VisibleResources) e il menu (NavigationVisibility): seicento righe che ogni pagina si portava dietro.
module OrganizationContext
  extend ActiveSupport::Concern

  included do
    helper_method :current_organization, :current_membership, :switchable_organizations,
                  :projects_view_preference
  end

  private

  # Modalità lista progetti: preferenza utente → default org → "cards". Solo record già caricati.
  def projects_view_preference
    Current.account&.projects_view.presence ||
      Current.organization&.default_projects_view.presence ||
      "cards"
  end

  def set_current_organization
    return set_current_organization_for_god if Current.true_account&.god?

    memberships = Current.account.memberships.includes(:organization)
    wanted = session[:organization_id]
    @current_membership = memberships.find { |m| m.organization_id == wanted } || memberships.first
    Current.organization = @current_membership&.organization
  end

  # Ramo god: org da session[:organization_id] — QUALSIASI, non solo le sue — con fallback (prima di cui
  # è membro → prima per nome). @current_membership è la sua membership lì SE esiste, altrimenti nil.
  def set_current_organization_for_god
    wanted = session[:organization_id]
    Current.organization =
      (wanted && Organizations::Organization.find_by(id: wanted)) ||
      Current.account.organizations.order(:name).first ||
      Organizations::Organization.order(:name).first
    @current_membership = Current.account.memberships.find_by(organization_id: Current.organization&.id)
  end

  def current_organization = Current.organization
  def current_membership = @current_membership

  # Org dello switcher: le proprie per i non-god; TUTTE per il god (cross-tenant nativo).
  def switchable_organizations
    return Organizations::Organization.order(:name) if Current.true_account&.god?

    Current.account.organizations
  end

  # Per i controller dell'area member: senza org non si entra.
  def require_organization
    return if Current.organization

    redirect_to(Current.account.god? ? valhalla_root_path : root_path,
                alert: t("member.no_organization"))
  end

  # CYRA-722 — organizzazione sospesa: nessuna pagina dell'area utenti si apre, e al posto di quella
  # richiesta si legge il motivo. Non un redirect alla home: anche la home è bloccata, e rimbalzare
  # fra due pagine chiuse non spiegherebbe niente. Il god passa (regge l'impersonation via
  # true_account): è lui a sospendere, e chiuderlo fuori non lascerebbe nessuno a rimettere in piedi.
  def require_active_organization
    return unless Current.organization&.suspended?
    return if Current.true_account&.god?

    # Le sole vie d'uscita: uscire, o un'altra org ancora attiva (le sospese riporterebbero qui).
    @other_active_organizations =
      Current.account.organizations.active.where.not(id: Current.organization.id).order(:name)

    render "shared/organization_suspended", layout: "application", status: :forbidden
  end
end
