# frozen_string_literal: true

module Member
  class MembersController < Member::BaseController
    # Whitelist ordinamento delle DUE tabelle della pagina (contratto Sortable#sorted):
    # membri su ?sort / inviti su ?invitations_sort (namespace separati come :page /
    # :invitations_page). role è enum int → ordina per gerarchia di dichiarazione.
    SORT_COLUMNS = {
      "member" => { expr: "LOWER(accounts.name)", joins: :account },
      "email" => { expr: "LOWER(accounts.email)", joins: :account },
      "role" => :role,
      "joined" => :created_at
    }.freeze
    INVITATIONS_SORT_COLUMNS = {
      "email" => "LOWER(connections_invitations.email)",
      "role" => :role,
      "invited" => :created_at
    }.freeze

    # CYRA-580 — le tre schede della pagina accessi, scelte da ?tab= e rese server-side (stesso
    # pattern del dettaglio ticket). La prima è di SOLA LETTURA ed è la predefinita: chi apre questa
    # pagina di solito vuole verificare cosa può fare una persona, non riconfigurarla, e per leggere
    # la verifica doveva attraversare centottantasei selettori a tre posizioni — con il rischio, solo
    # scorrendo, di cambiarne uno per sbaglio.
    ACCESS_TABS = %w[effective access overrides].freeze

    # I quattro blocchi salvabili della pagina, nell'ordine che l'atomicità richiede (CYRA-243):
    # ruoli e permessi prima, scope per ultimo. Ognuno decide da sé se il modulo lo ha inviato.
    ACCESS_STEPS = %i[apply_direct_roles apply_overrides apply_secret_environments apply_member_scope].freeze

    before_action :require_view, only: %i[index]
    before_action :require_edit, only: %i[edit update]
    before_action :forbid_protected_target!, only: %i[edit update]
    before_action :require_management, only: %i[role destroy access update_access access_preview]
    before_action :require_actor_privileged!, only: %i[access_preview]

    # CYRA-728 — come per i team: il what-if per-membro disegna il risultato di una modifica che non
    # è stata ancora salvata. Chiedere conferma per guardare insegnerebbe a confermare senza leggere.
    confirmation_not_required "ricalcola e mostra i permessi pendenti del membro, non ne salva nessuno",
                              only: :access_preview

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :role, :q, :sort, :invitations_sort, only: :index

    def index
      scope = Current.organization.memberships.includes(:account).order(:role)
      scope = scope.where(role: filter_ids(:role)) if filter_ids(:role).any?
      if search_q.present?
        scope = scope.joins(:account)
                     .where("accounts.name ILIKE :q OR accounts.email ILIKE :q", q: "%#{search_q}%")
      end
      @members_pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @memberships = @members_pagination.records
      @member_teams = member_teams_by_account(@memberships)
      # CYRA-555 — a zero corrispondenze qui non compariva NIENTE: restava l'intestazione della
      # tabella alta 34px, senza una parola. Serve sapere che è stata la ricerca (o il filtro sul
      # livello) a svuotarla, e quante persone ci sono davvero — che è anche il numero del chip.
      @members_filtering = search_q.present? || filter_ids(:role).any?
      # CYRA-556 — un numero solo sommava le persone alle utenze usate dai programmi: diceva tredici
      # membri con nove colleghi in casa. Due popolazioni diverse, due numeri, dallo stesso elenco di
      # membership che riempie la tabella (mai una seconda sorgente che col tempo diverge).
      members = Current.organization.memberships.joins(:account)
      @total_members = members.merge(Accounts::Account.human).count
      @total_service_accounts = members.merge(Accounts::Account.service).count

      invitations = Current.organization.invitations.pending.order(created_at: :desc)
      invitations = sorted(invitations, columns: INVITATIONS_SORT_COLUMNS, param: :invitations_sort)
      @invitations_pagination = paginate(invitations, :invitations_page)
      @invitations = @invitations_pagination.records
      @saved_views = saved_views_for("members")
    end

    # Display fields are global; the recovery email is read-only in membership management.
    def edit
      @membership = scoped_membership
      @account = @membership.account
    end

    def update
      @membership = scoped_membership
      @account = @membership.account
      result = Accounts::Update.call(account: @account, attributes: account_params)
      if result.ok?
        redirect_to member_members_path, notice: t("member.members.updated")
      else
        @errors = result.error.details
        render :edit, status: :unprocessable_content
      end
    end

    def role
      result = Connections::ChangeRole.call(membership: scoped_membership, role: params[:role])
      if result.ok?
        redirect_to member_members_path, notice: t("member.members.role_changed")
      else
        redirect_to member_members_path, alert: result.error.message
      end
    end

    def destroy
      result = Connections::RemoveMember.call(membership: scoped_membership)
      if result.ok?
        redirect_to member_members_path, notice: t("member.members.removed")
      else
        redirect_to member_members_path, alert: result.error.message
      end
    end

    # Accessi & permessi per member/customer: scope (gruppi/progetti) + ruoli diretti + override
    # personali (allow/deny) con l'origine effettiva. owner/admin sono unscoped → banner, nessun form.
    def access
      @tab = access_tab
      @membership = scoped_membership
      @account = @membership.account
      org = Current.organization
      @groups = org.groups.ordered
      @projects = org.projects.order(:name)
      @roles = org.roles.ordered
      @selected_group_ids = current_group_ids(@account, org)
      @selected_project_ids = current_project_ids(@account, org)
      @selected_role_ids = current_role_ids(@account, org)
      @overrides = current_overrides(@account, org)
      @effective_role_keys = effective_role_keys(@account, org)
      load_secret_environments(org)

      # Schema permessi effettivi (owner/god), in cima alla scheda di sola lettura e accanto ai
      # comandi nelle altre due. Non serve per un target owner (vede tutto).
      return unless actor_privileged? && !@membership.owner?

      @access_matrix = [ Authorization::PreviewAccess::Member.call(
        organization: org, account: @account, projects: @projects,
        params: { group_ids: @selected_group_ids, project_ids: @selected_project_ids,
                  role_ids: @selected_role_ids, overrides: @overrides }
      ) ]
    end

    # Schema what-if (owner/god): ricalcola i permessi effettivi dell'account coi params PENDENTI del
    # form (zero persistenza) e rende il partial. Vedi Authorization::PreviewAccess::Member.
    def access_preview
      membership = scoped_membership
      account = membership.account
      org = Current.organization
      diff = Authorization::PreviewAccess::Member.call(
        organization: org, account: account, projects: org.projects.order(:name),
        params: access_preview_params(account, org)
      )
      render partial: "member/shared/access_matrix", locals: { subjects: [ diff ] }
    end

    def update_access
      membership = scoped_membership
      result = apply_access(membership)
      if result.ok?
        redirect_to member_members_path, notice: t("member.members.access_updated")
      else
        # Torna sulla scheda da cui si stava salvando: l'alert dice cosa è stato rifiutato, e i campi
        # da correggere devono essere quelli che si ha davanti.
        redirect_to access_member_member_path(membership, tab: access_redirect_tab), alert: result.error.message
      end
    end

    private

    # Scheda corrente della pagina accessi. Fuori whitelist → il riepilogo di sola lettura, mai una
    # scheda vuota.
    def access_tab
      ACCESS_TABS.include?(params[:tab]) ? params[:tab] : ACCESS_TABS.first
    end

    # `nil` sulla scheda predefinita: l'indirizzo resta pulito e un salvataggio che non dichiara la
    # scheda (canale non-web, form vecchio) torna dov'era prima.
    def access_redirect_tab
      tab = access_tab
      tab == ACCESS_TABS.first ? nil : tab
    end

    # Scoping all'org corrente → un id di altra org dà RecordNotFound (anti-BOLA).
    def scoped_membership
      @scoped_membership ||= Current.organization.memberships.find(params[:id])
    end

    # email/handle sono credenziali GLOBALI: un cambio non verificato consentirebbe il takeover
    # via password reset. Un attore non privilegiato (né owner né god) NON può quindi modificare i
    # dati anagrafici di un target protetto (l'owner dell'org o un account god) → escalation. Owner/god
    # editano chiunque. Speculare ai guard su owner di Connections::ChangeRole / RemoveMember.
    def forbid_protected_target!
      return if actor_privileged?

      target = scoped_membership
      return unless target.owner? || target.account.god?

      Rails.logger.warn(
        "Protected member edit denied — account=#{Current.account&.id} " \
        "org=#{Current.organization&.id} target=#{target.id} path=#{request.path}"
      )
      redirect_to member_members_path, alert: t("member.forbidden")
    end

    # Solo i tre campi anagrafici del form — MAI role/god/preferences da questo canale.
    def account_params
      params.permit(:name, :email, :handle)
    end

    # CYRA-440: i team di ciascun membro in pagina, coi ruoli portati e lo scope — precaricati in
    # blocco (roles + scope) e raggruppati per account_id. La colonna "Livello" è la membership d'org;
    # i permessi effettivi arrivano da qui. Un solo preload → la riga NON fa N+1 sui 12+ membri.
    def member_teams_by_account(memberships)
      account_ids = memberships.map(&:account_id).uniq
      return {} if account_ids.empty?

      Connections::TeamMembership
        .where(account_id: account_ids, team: Current.organization.teams)
        .includes(team: %i[roles scoped_projects scoped_groups])
        .group_by(&:account_id)
        .transform_values { |links| links.map(&:team).sort_by { |team| team.name.downcase } }
    end

    # Chiavi concesse dai ruoli effettivi dell'account (ruoli diretti + ruoli dei team) nell'org —
    # per mostrare l'ORIGINE "via roles" nella UI degli override.
    def effective_role_keys(account, org)
      direct = account.account_roles.where(organization_id: org.id).pluck(:role_id)
      team_ids = account.teams.where(organization_id: org.id).pluck(:id)
      team = Authorization::TeamRole.where(team_id: team_ids).pluck(:role_id)
      Authorization::RolePermission.where(role_id: (direct + team).uniq).distinct.pluck(:permission_key).to_set
    end

    # Params pendenti dello schema what-if (identici al form di update_access).
    #
    # CYRA-580 — il modulo di una scheda invia SOLO i propri campi, e il preview applica sempre tutti
    # e tre i blocchi: quello che non arriva vale lo stato ATTUALE, non "vuoto". Senza questo, aprendo
    # le eccezioni lo schema dipingeva di rosso barrato ruoli e progetti che nessuno stava togliendo —
    # un allarme su una rimozione che il salvataggio non farebbe (#apply_access li lascia intatti), e
    # sullo schema si decide se un accesso è giusto.
    def access_preview_params(account, org)
      { group_ids: params.fetch(:group_ids) { current_group_ids(account, org) },
        project_ids: params.fetch(:project_ids) { current_project_ids(account, org) },
        role_ids: params.fetch(:role_ids) { current_role_ids(account, org) },
        overrides: params.fetch(:overrides) { current_overrides(account, org) } }
    end

    # Stato persistito dei blocchi del form: gli stessi valori con cui #access popola i selettori.
    def current_group_ids(account, org) = account.accessible_groups.where(organization_id: org.id).pluck(:id)
    def current_project_ids(account, org) = account.directly_accessible_projects.where(organization_id: org.id).pluck(:id)
    def current_role_ids(account, org) = account.account_roles.where(organization_id: org.id).pluck(:role_id)

    def current_overrides(account, org)
      account.account_permissions.where(organization_id: org.id)
             .each_with_object({}) { |permission, all| all[permission.permission_key] = permission.effect }
    end

    # CYRA-243: le tre operazioni (ruoli, override, scope) sono ATOMICHE. Ogni guard di escalation/
    # visibilità (R403-ACCESS-001) gira PRIMA della propria transazione, quindi al primo Result::err
    # annullo tutto (rollback) e propago l'errore: quando il salvataggio è rifiutato NULLA resta
    # applicato, come promette il messaggio (prima lo scope committava per primo e restava salvato anche
    # se ruoli/override venivano rifiutati). Ruoli e override PRIMA, scope per ULTIMO (parità sync_team).
    def apply_access(membership)
      result = Result.ok
      ActiveRecord::Base.transaction do
        ACCESS_STEPS.each do |step|
          outcome = send(step, membership)
          next if outcome.nil? # blocco non inviato dal modulo: si lascia com'è

          result = outcome
          raise ActiveRecord::Rollback if result.err?
        end
      end
      result
    end

    # CYRA-580 — ogni blocco si applica SOLO se il modulo lo ha inviato. Con le tre schede il form
    # porta i campi della scheda aperta, e quello che non è in pagina non deve sparire dal database:
    # senza questa guardia salvare le eccezioni azzerava ruoli, gruppi e progetti in silenzio. Il
    # campo nascosto dei multi-select fa sì che "svuotare" resti comunque possibile — l'assenza della
    # chiave vuol dire "non toccare", non "azzera". Stesso principio del confine ambienti (CYRA-78).
    def apply_direct_roles(membership)
      return nil unless params.key?(:role_ids)

      Authorization::SetAccountRoles.call(organization: Current.organization, account: membership.account,
                                          role_ids: params[:role_ids], actor: Current.account,
                                          true_actor: Current.true_account)
    end

    def apply_overrides(membership)
      return nil unless params.key?(:overrides)

      allow_keys, deny_keys = split_overrides(params[:overrides])
      Authorization::SetAccountPermissions.call(organization: Current.organization, account: membership.account,
                                                allow_keys: allow_keys, deny_keys: deny_keys,
                                                actor: Current.account, true_actor: Current.true_account)
    end

    def apply_member_scope(membership)
      return nil unless params.key?(:group_ids) || params.key?(:project_ids)

      Connections::SetMemberAccess.call(organization: Current.organization, account: membership.account,
                                        group_ids: params[:group_ids], project_ids: params[:project_ids],
                                        actor: Current.account)
    end

    # Confine ambienti sui secret (CYRA-78). Si applica SOLO se il form ha reso la card: sui target
    # unscoped (owner) la sezione non esiste, e un POST senza quei campi non deve azzerare in silenzio
    # una restrizione impostata altrove. `to_unsafe_h` è sicuro qui perché Connections::SetSecretAccess
    # sanifica tutto — code ai soli ambienti reali dell'org, progetti ai soli dell'org.
    def apply_secret_environments(membership)
      return nil unless params.key?(:secret_environment_codes) || params.key?(:project_secret_environments)

      per_project = params[:project_secret_environments].presence&.to_unsafe_h || {}
      Connections::SetSecretAccess.call(membership: membership,
                                        org_wide_codes: params[:secret_environment_codes],
                                        per_project: per_project)
    end

    # Dati della card «ambienti dei segreti»: allow-list org-wide, override già impostati e progetti su
    # cui ha senso dichiararne uno (quelli che il membro vede DIRETTAMENTE, più quelli che hanno già un
    # override — un confine su un progetto invisibile non servirebbe a nessuno).
    def load_secret_environments(org)
      @grantable_environments = org.environments.order(:code).to_a
      @secret_environment_codes = @membership.secret_environment_codes
      @project_secret_environments = Connections::AccountSecretAccess
                                     .where(account_id: @account.id, organization_id: org.id)
                                     .pluck(:project_id, :environment_codes).to_h
      @secret_environment_projects = org.projects
                                        .where(id: @selected_project_ids | @project_secret_environments.keys)
                                        .order(:name).to_a
    end

    # params[:overrides] = { key => "inherit|allow|deny" } → [allow_keys, deny_keys].
    def split_overrides(overrides)
      allow = []
      deny = []
      overrides&.each_pair do |key, value|
        allow << key if value == "allow"
        deny << key if value == "deny"
      end
      [ allow, deny ]
    end

    # Lettura lista: gata da members.view; chi gestisce (members.manage) vede sempre.
    def require_view
      require_permission!("members.view") unless can?("members.manage")
    end

    def require_edit
      require_permission!("members.edit")
    end

    def require_management
      require_permission!("members.manage")
    end
  end
end
