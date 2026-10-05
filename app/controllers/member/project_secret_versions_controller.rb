# frozen_string_literal: true

module Member
  # Storico versioni + rollback di un secret del vault (Fase 3). Controller flat (come ProjectSecretsController).
  # La LISTA (numero, autore, data: metadati) si apre con `secrets.read` o `secrets.manage`; il VALORE di
  # una versione è gated `secrets.read`; il rollback (mutazione) `secrets.manage`. Anti-BOLA all'org visibile.
  class ProjectSecretVersionsController < Member::BaseController
    include Member::SecretEnvironmentBoundary

    before_action :set_project
    before_action :set_secret
    before_action :require_secrets_access, only: :index
    before_action :require_secrets_read, only: :reveal
    before_action :require_secrets_manage, only: :rollback
    # CYRA-666 — il confine ambienti DOPO il permesso: prima si stabilisce se puoi fare la cosa, poi
    # se puoi farla QUI. Vale su tutte e tre le azioni, lettura compresa: lo storico e' l'altra strada
    # verso il valore in chiaro, e senza questo gate un account confinato a staging leggeva dalla
    # versione il valore di produzione che la matrice gli nega.
    before_action :require_secret_environment, only: %i[index reveal rollback]

    def index
      @versions = @secret.versions.includes(:created_by).ordered.to_a
      @stats = @project.ticket_tally
    end

    # Rivela il valore in chiaro di UNA versione storica SOLO su richiesta esplicita (CYRA-204): lo storico
    # non rende più i valori nel sorgente HTML (li leggerebbe chi apre il sorgente, corrente compresa,
    # aggirando il reveal della matrice — CYRA-202). Il valore viaggia verso il client solo qui, dietro il
    # gate secrets.read, e l'accesso è registrato nell'audit ("read", per-versione: name + environment).
    # Anti-BOLA: la versione è risolta DENTRO @secret.versions (@secret già scoped al progetto visibile).
    def reveal
      version = @secret.versions.find(params[:id])
      ::Secrets::RecordEvent.call(action: "read", project: @project, environment: @secret.environment,
                                  actor: Current.account, name: @secret.name, channel: "web",
                                  metadata: { count: 1, source: "web", version: version.number })
      # Il valore in chiaro non deve persistere nella cache HTTP del browser (disco/memoria).
      response.headers["Cache-Control"] = "no-store"
      render json: { value: version.value }
    end

    # Instrada attraverso Submit (CYRA-138 C1b): su un ambiente protetto NON ripristina, crea una change
    # request pending con il valore della versione e source_version tracciata. `version` è risolta
    # dentro `@secret.versions` (scope anti-BOLA), quindi appartiene già a @secret per costruzione — il
    # guard cross-secret di Secrets::Variables::Rollback (R422-SECRET-003) non serve più su questo
    # percorso web.
    def rollback
      version = @secret.versions.find(params[:id])
      result = ::Secrets::ChangeRequests::Submit.call(
        project: @project, environment: @secret.environment, name: @secret.name,
        action: :set, value: version.value, source_version: version, actor: Current.account
      )

      notice = result.ok? && result.value.pending? ? t("member.secrets.pending_approval", name: @secret.name) : t("member.secrets.rolled_back")
      redirect_to member_project_secret_versions_path(@project, @secret), notice: notice
    end

    private

    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def set_secret
      @secret = @project.secret_variables.find(params[:secret_id])
    end

    # CYRA-721 — come nella matrice: la lista delle versioni è un metadato e serve anche a chi gestisce
    # (senza, non troverebbe la versione da ripristinare); il valore di una versione è in chiaro, quindi
    # esce solo con `secrets.read`. Lo storico è l'altra strada verso il valore: se accettasse ancora
    # `secrets.manage` sarebbe la porta di servizio della cella che la matrice tiene chiusa.
    def require_secrets_access
      return if can?("secrets.read", scope: @project) || can?("secrets.manage", scope: @project)

      redirect_to root_path, alert: t("member.forbidden")
    end

    def require_secrets_read
      return if can?("secrets.read", scope: @project)

      redirect_to root_path, alert: t("member.forbidden")
    end

    def require_secrets_manage
      require_permission!("secrets.manage", scope: @project)
    end

    # Il secret appartiene a UN ambiente, quindi la decisione e' una sola per richiesta. La forma del
    # rifiuto cambia col canale: `reveal` risponde JSON perche' la cella si sblocca via fetch e un
    # redirect non lo vedrebbe nessuno (stesso motivo di ProjectSecretsController#reveal); le altre due
    # rimbalzano come fa gia' il gate del permesso qui sopra. In entrambi i casi il tentativo lascia
    # l'evento "denied" nell'audit PRIMA del rifiuto.
    def require_secret_environment
      return if environment_allowed?(@secret.environment)

      record_environment_denied(@secret.environment, name: @secret.name)

      if action_name == "reveal"
        render json: { error: t("member.secrets.environment_denied") }, status: :forbidden
      else
        redirect_to root_path, alert: t("member.secrets.environment_denied")
      end
    end
  end
end
