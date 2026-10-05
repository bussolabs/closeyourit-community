# frozen_string_literal: true

module Member
  class SharedSecretsController < Member::BaseController
    before_action :require_access

    def index
      load_page
    end

    # Salva una RIGA della matrice: un nome su N ambienti (upsert per cella, blank saltati). La riga
    # di creazione e il Salva di una riga esistente postano entrambi qui. Rotazione di valori delegati
    # → R409 con impatto AGGREGATO (banner) + valori preservati; validazione fallita → R422.
    def create
      result = ::Secrets::Shared::Rows::Save.call(
        organization: Current.organization, name: params[:name],
        cells: row_cells, actor: Current.account, confirmation_digest: params[:confirmation_digest]
      )
      return redirect_to(member_shared_secrets_path, notice: t("member.shared_secrets.saved")) if result.ok?

      if result.error.code == "R409-SHARED-001"
        @impact = result.error.details
      else
        @row_errors = result.error.details || { base: [ result.error.message ] }
      end
      @open_row = params[:name].to_s.strip.upcase.presence
      load_page
      render :index, status: :unprocessable_content
    end

    def impact
      value = scoped_variable.values.find(params[:value_id])
      render json: ::Secrets::Shared::Impact.call(shared_value: value, effect: params[:effect]).value
    end

    # Rivela il valore in chiaro di un value condiviso SOLO su richiesta esplicita (CYRA-202): la matrice
    # non rende più i valori nel sorgente HTML. Il valore viaggia verso il client solo qui, dietro il
    # gate shared_secrets.manage, e l'accesso è registrato nell'audit ("revealed"). Anti-BOLA: la
    # variabile è risolta in Current.organization e il value DENTRO la variabile (value_id estraneo → 404).
    def reveal
      value = scoped_variable.values.find(params[:value_id])
      record_reveal(value)
      # Il valore in chiaro non deve persistere nella cache HTTP del browser (disco/memoria).
      response.headers["Cache-Control"] = "no-store"
      render json: { value: value.value }
    end

    def destroy
      variable = scoped_variable
      result = ::Secrets::Shared::Delete.call(shared_variable: variable, actor: Current.account,
                                               confirmation_digests: params[:confirmation_digests])
      redirect_to member_shared_secrets_path, **(result.ok? ? { notice: t("member.shared_secrets.deleted") } : { alert: t("member.shared_secrets.stale") })
    end

    private

    def scoped_variable = Current.organization.shared_secret_variables.find(params[:id])

    def require_access = require_permission!("shared_secrets.manage")

    # Audit append-only dell'accesso al valore (CYRA-202). Fire-and-forget: un audit che fallisce non
    # deve rompere la lettura (stesso principio di Secrets::RecordEvent per il vault di progetto).
    def record_reveal(value)
      ::Secrets::Shared::Event.create!(
        organization: value.organization, shared_variable: value.shared_variable, environment: value.environment,
        actor: Current.account, name: value.name, action: "revealed"
      )
    rescue StandardError => e
      Rails.logger.warn("Shared secret audit event failed: #{e.class} #{e.message}")
      nil
    end

    # Celle inviate dal form-riga, filtrate agli ambienti REALI dell'org (subset-security: un env_id
    # estraneo / di un'altra org nei params viene ignorato prima ancora del service). Il service salta
    # le celle con valore blank (svuotare non cancella — il delete è esplicito per cella).
    def row_cells
      (@environments || Current.organization.environments.active.ordered.to_a).filter_map do |environment|
        value = params.dig(:values, environment.id.to_s)
        next if value.nil?

        { environment:, value: value.to_s }
      end
    end

    def load_page
      @environments = Current.organization.environments.active.ordered.to_a
      @variables = Current.organization.shared_secret_variables.includes(values: [ :environment, :versions, { projects: :github_repository } ]).order(:name)
      @projects = Current.organization.projects.includes(:environments, :project_environments).order(:name)
      @events = Current.organization.shared_secret_events.includes(:actor, :project, :environment).recent.limit(20)
      load_secret_readers
    end

    # CYRA-422 — «Chi può vedere questi segreti» dell'organizzazione: le membership reali con
    # shared_secrets.manage. Chi arriva qui ha già quel permesso (require_access), quindi vede i nomi;
    # il ramo a solo conteggio resta per coerenza con le altre pagine. Batch (niente N+1 nel render).
    def load_secret_readers
      @secret_readers = ::Secrets::Readers.for_organization(Current.organization)
      @secret_readers_reveal = can?("members.view") || can?("shared_secrets.manage")
      @secret_readers_permissions_href = member_members_path if can?("members.view")
    end
  end
end
