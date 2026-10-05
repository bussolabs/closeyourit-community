# frozen_string_literal: true

module Member
  # CRUD dei ruoli dinamici dell'org (bundle di chiavi-permesso). Gated da `permissions.manage`
  # (owner sempre; altri solo se delegati). Le chiavi sono riconciliate via SetRolePermissions →
  # modifica = propaga LIVE ai team/utenti col ruolo. Scoping anti-BOLA all'org corrente.
  class RolesController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted). used_by = somma dei portatori
    # (team + utenti diretti), stesse fonti dei badge in riga.
    SORT_COLUMNS = {
      "role" => "LOWER(authorization_roles.name)",
      "permissions" => "(SELECT COUNT(*) FROM authorization_role_permissions rp " \
                       "WHERE rp.role_id = authorization_roles.id)",
      "used_by" => "((SELECT COUNT(*) FROM authorization_team_roles tr WHERE tr.role_id = authorization_roles.id) " \
                   "+ (SELECT COUNT(*) FROM authorization_account_roles ar WHERE ar.role_id = authorization_roles.id))"
    }.freeze

    before_action :require_manage
    before_action :set_role, only: %i[show edit update destroy]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :q, only: :index

    def index
      scope = Current.organization.roles.ordered
      scope = scope.where("authorization_roles.name ILIKE :q", q: "%#{search_q}%") if search_q.present?
      @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @roles = @pagination.records
      role_ids = @roles.map(&:id)
      # Le chiavi per ruolo in UNA query: l'elenco mostra le aree toccate, e chiederle per riga
      # sarebbe una query per ruolo.
      @keys_by_role = Authorization::RolePermission.where(role_id: role_ids)
                                                   .pluck(:role_id, :permission_key)
                                                   .group_by(&:first)
                                                   .transform_values { |rows| rows.map(&:last) }
      @key_counts = @keys_by_role.transform_values(&:size)
      @team_counts = Authorization::TeamRole.where(role_id: role_ids).group(:role_id).count
      @account_counts = Authorization::AccountRole.where(role_id: role_ids).group(:role_id).count
      # CYRA-555 — come sui team: il chip conta i ruoli che esistono, non quelli sopravvissuti alla
      # ricerca, così a zero corrispondenze non contraddice il messaggio sotto.
      @total_roles = Current.organization.roles.count
    end

    # CYRA-439 — scheda di SOLA LETTURA di un ruolo: per sapere cosa concedeva bisognava aprire il
    # modulo di modifica, che ha «Elimina» e «Salva» in cima. Capire non deve costare il rischio di
    # cambiare.
    def show
      @entries = @role.permission_keys.filter_map { |key| Authorization::Catalog.entry(key) }
      @teams_count = Authorization::TeamRole.where(role_id: @role.id).count
      @accounts_count = Authorization::AccountRole.where(role_id: @role.id).count
    end

    def new
      @role = Current.organization.roles.new
      @selected_keys = []
    end

    def create
      @role = Current.organization.roles.new(role_params)
      @role.created_by = Current.account
      if @role.save
        result = sync_permissions
        if result.ok?
          redirect_to member_roles_path, notice: t("member.roles.created")
        else
          # Escalation bloccata (R403-ACCESS-001): il ruolo appena creato è vuoto (fail-fast, nessuna
          # chiave aggiunta) → lo rimuovo e rimando indietro con l'errore leggibile, mai un 500.
          @role.destroy
          redirect_to new_member_role_path, alert: result.error.message
        end
      else
        @errors = @role.errors.to_hash
        @selected_keys = permission_keys
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @selected_keys = @role.permission_keys
    end

    def update
      if @role.update(role_params)
        result = sync_permissions
        if result.ok?
          redirect_to member_roles_path, notice: t("member.roles.updated")
        else
          # Escalation bloccata (R403-ACCESS-001): i permessi NON sono cambiati (fail-fast) → rimando al
          # form con l'errore leggibile. Il name/color eventualmente aggiornati restano (non è escalation).
          redirect_to edit_member_role_path(@role), alert: result.error.message
        end
      else
        @errors = @role.errors.to_hash
        @selected_keys = permission_keys
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @role.destroy
      redirect_to member_roles_path, notice: t("member.roles.deleted")
    end

    private

    # Anti-BOLA: un id di un'altra org → RecordNotFound.
    def set_role
      @role = Current.organization.roles.find(params[:id])
    end

    def role_params
      params.permit(:name, :color)
    end

    def permission_keys
      Array(params[:permission_keys]).reject(&:blank?)
    end

    def sync_permissions
      Authorization::SetRolePermissions.call(
        role: @role, permission_keys: permission_keys,
        actor: Current.account, true_actor: Current.true_account
      )
    end

    def require_manage
      require_permission!("permissions.manage")
    end
  end
end
