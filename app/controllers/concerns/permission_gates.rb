# frozen_string_literal: true

# CYRA-740 — chi può fare cosa, nell'area utenti. Estratto da OrganizationContext, che teneva i
# permessi insieme al contesto organizzazione, agli elenchi visibili di ogni dominio e al menu: una
# pagina che doveva solo sapere in quale organizzazione si trova se li portava dietro tutti.
#
# Qui vivono il resolver per-richiesta, il predicato che le viste interrogano (`can?`), le scorciatoie
# org-level (manage-implies-view) e le due guardie che negano — quella a permesso e quella owner/god.
module PermissionGates
  extend ActiveSupport::Concern

  # CYRA-728 — le azioni segnate `dangerous` nel catalogo non partono senza una conferma esplicita.
  include DangerousActionConfirmation

  included do
    # CYRA-799 — `note_permission_check!` è qui perché il menu lo chiama dalla facciata pubblica del
    # controller e non più dai suoi metodi privati; dalle viste è inerte (la finestra è già chiusa).
    helper_method :can?, :can_any?, :can_manage_permissions?, :actor_privileged?,
                  :can_view_members?, :can_view_platforms?, :can_view_environments?,
                  :can_view_groups?, :can_view_servers?, :can_view_agents?,
                  :can_view_uptime_groups?, :can_view_product_features?,
                  :note_permission_check!
  end

  private

  # Resolver per-richiesta (cache interna): account + org correnti. Vedi Authorization::Resolver.
  def current_resolver
    @current_resolver ||= Authorization::Resolver.new(account: Current.account, organization: Current.organization)
  end

  # Helper viste/controller: l'account corrente può fare `key` (eventualmente sullo scope `scope`)?
  def can?(key, scope: nil)
    note_permission_check!
    current_resolver.can?(key, scope: scope)
  end

  # Vero se l'account può fare `key` su ALMENO un progetto visibile (per le affordance di pagine
  # multi-progetto: board/index). owner → vero (vede tutto e può tutto).
  def can_any?(key)
    visible.projects.any? { |project| can?(key, scope: project) }
  end

  # --- La finestra in cui il gate conta (CYRA-727) ------------------------------------------
  # Chi interroga i permessi lascia un segno; a leggerlo è la rete dell'area member
  # (Member::PermissionDeclaration#verify_permission_declared), che pretende da ogni pagina un gate
  # o un motivo scritto. Fuori da quell'area nessuno lo guarda, e costa un booleano.
  #
  # Conta solo ciò che accade PRIMA del render: `can?` è un helper delle viste e la barra laterale lo
  # interroga per ogni voce di menu a ogni pagina — senza chiudere la finestra, ogni pagina
  # risulterebbe controllata per il solo fatto di essersi disegnata, e la rete non prenderebbe niente.
  # A chiuderla è Member::PermissionDeclaration#render, che è dove il render passa.
  def note_permission_check!
    @permission_checked = true unless @permission_window_closed
  end

  def permission_checked? = @permission_checked || false

  # L'azione esce PRIMA di sapere su cosa chiedere il permesso: la selezione è vuota, l'id non
  # esiste, il record non è fra quelli visibili. Non c'è ancora niente da autorizzare, e va detto —
  # altrimenti la rete vede un'uscita senza gate proprio dove il gate viene due righe più sotto.
  def nothing_to_authorize! = note_permission_check!

  # Scorciatoia per il gate delle pagine RBAC (ruoli/team/accessi).
  def can_manage_permissions?
    can?("permissions.manage")
  end

  # Attore "privilegiato": owner dell'org corrente o god (regge l'impersonation via true_account).
  # Solo un attore privilegiato può modificare i dati anagrafici di un target protetto (owner/god) —
  # vedi Member::MembersController#forbid_protected_target!. Safe-nav su current_membership: un god
  # in un'org di cui non è membro ha current_membership nil (short-circuita comunque su god?).
  def actor_privileged?
    Current.true_account.god? || current_membership&.owner?
  end

  # Visibilità pagine org-level: chi gestisce vede sempre (manage-implies-view). Usati dai
  # controller (gate index/show) e dalle viste (nav + affordance). Vedi rules/authorization.md.
  #
  # CYRA-799 — la regola sta scritta UNA volta, in can_view_area?: è la stessa che
  # Authorization::VisibleScope chiede per i suoi due elenchi org-level, e due copie divergono.
  def can_view_area?(area) = can?("#{area}.view") || can?("#{area}.manage")

  def can_view_members?      = can_view_area?("members")
  def can_view_platforms?    = can_view_area?("platforms")
  def can_view_environments? = can_view_area?("environments")
  def can_view_groups?       = can_view_area?("project_groups")

  def can_view_product_features? = can_view_area?("product_features")

  # Server monitoring e agent host sono risorse ORG-LEVEL (non per-progetto): la visibilità è a
  # permesso, non a scope. Il catalogo dei typed agent è stato rimosso (MT-9): l'elenco degli host
  # vive in Member::AgentsController, che scopa già su `current_organization.agent_hosts`.
  def can_view_servers? = can_view_area?("servers")
  def can_view_agents? = can_view_area?("agents")
  def can_view_uptime_groups? = can_view_area?("uptime_groups")

  # Guard a permesso: nega (redirect 403-like) se l'account non ha `key`. Logga il denied.
  #
  # CYRA-728 — poi c'è la seconda domanda, per le sole chiavi `dangerous` del catalogo su una
  # richiesta che scrive: l'ha confermato qualcuno? Il permesso dice CHI può, la conferma dice che
  # questa volta lo vuole davvero. Sono due gate distinti e danno due risposte distinte: mancare il
  # permesso rimbalza alla home, mancare la conferma mostra la pagina che spiega cosa serve fare.
  def require_permission!(key, scope: nil)
    unless can?(key, scope: scope)
      Rails.logger.warn(
        "Permission denied — account=#{Current.account&.id} org=#{Current.organization&.id} " \
        "key=#{key} path=#{request.path}"
      )
      return redirect_to(root_path, alert: t("member.forbidden"))
    end

    enforce_dangerous_confirmation!(key, scope: scope)
  end

  # Manca la conferma. Non è un redirect con avviso: il gesto che l'utente stava facendo va ripreso
  # da dove l'ha lasciato, e una home con una striscia gialla non gli direbbe cosa fare adesso. Il
  # 422 è anche quello che il canale macchina si aspetta quando la richiesta è comprensibile ma
  # incompleta — la riga di comando manca del suo `--yes`, non di un permesso.
  def deny_unconfirmed_dangerous_action(key)
    @dangerous_action_key = key
    @dangerous_action_params = repeatable_dangerous_params

    # Una pagina per chi guarda, l'envelope per chi no. Nell'area utenti ci sono comandi che partono
    # da un fetch e si aspettano JSON: rispondere loro con del markup li lascerebbe senza niente da
    # leggere, ed è il modo in cui un rifiuto diventa un guasto muto.
    respond_to do |format|
      format.json do
        render json: { error: { code: DangerousActionConfirmation::MISSING_CONFIRMATION_CODE, message: t("member.confirmation_required.title") } },
               status: :unprocessable_content
      end
      format.any do
        render "shared/confirmation_required", layout: "application", formats: :html,
               status: :unprocessable_content
      end
    end
  end

  # La pagina di conferma rifà la stessa richiesta, con la conferma dentro: perché lo faccia le
  # servono i parametri di partenza, meno quelli che descrivono la rotta (li rimette il path) e meno
  # la conferma stessa. Un allegato non si può ripetere da qui — il browser non ce l'ha più — e in
  # quel caso non si finge di poterlo fare: resta la sola via del ritorno.
  def repeatable_dangerous_params
    original_params = request.params.except("controller", "action", Authorization::DangerousAction::CONFIRM_PARAM.to_s)
    repeatable_params?(original_params) ? original_params : nil
  end

  def repeatable_params?(value)
    case value
    when Hash  then value.values.all? { |nested| repeatable_params?(nested) }
    when Array then value.all? { |nested| repeatable_params?(nested) }
    when String, Numeric, TrueClass, FalseClass, NilClass then true
    else false
    end
  end

  # Guard owner/god-only per lo schema what-if (actor_privileged? = owner dell'org corrente o god).
  # Le pagine sono già gated members.manage/permissions.manage, ma quelli NON implicano owner.
  def require_actor_privileged!
    note_permission_check!
    return if actor_privileged?

    Rails.logger.warn(
      "Owner/god required — account=#{Current.account&.id} org=#{Current.organization&.id} path=#{request.path}"
    )
    redirect_to root_path, alert: t("member.forbidden")
  end
end
