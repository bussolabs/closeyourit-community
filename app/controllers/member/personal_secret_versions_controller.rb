# frozen_string_literal: true

module Member
  # Storico versioni + rollback di un secret del vault PERSONALE. Ownership (nessuna permission key);
  # anti-BOLA via lo scope .for dell'account. Controller flat (come PersonalSecretsController).
  class PersonalSecretVersionsController < Member::BaseController
    permission_not_required "Storico della propria cassaforte personale: lo scope per account è anche il confine."

    before_action :set_secret

    def index
      @versions = @secret.versions.ordered.to_a
    end

    # Rivela il valore in chiaro di UNA versione storica SOLO su richiesta esplicita (CYRA-204): lo storico
    # non rende più i valori nel sorgente HTML (li leggerebbe chi apre il sorgente, corrente compresa,
    # aggirando il reveal della lista). Il valore viaggia verso il client solo qui e l'accesso è registrato
    # nell'audit ("read", source web). Anti-BOLA: @secret è già scoped .for(account, org) (set_secret),
    # la versione è risolta dentro @secret.versions.
    def reveal
      version = @secret.versions.find(params[:id])
      ::Secrets::Personal::RecordEvent.call(action: "read", account: Current.account,
                                            organization: Current.organization,
                                            name: @secret.name, metadata: { count: 1, source: "web" })
      # Il valore in chiaro non deve persistere nella cache HTTP del browser (disco/memoria).
      response.headers["Cache-Control"] = "no-store"
      render json: { value: version.value }
    end

    def rollback
      version = @secret.versions.find(params[:id])
      ::Secrets::Personal::Variables::Rollback.call(variable: @secret, version:)
      redirect_to member_personal_secret_versions_path(@secret), notice: t("member.personal_secrets.rolled_back")
    end

    private

    # Anti-BOLA: secret di un altro account/altra org → RecordNotFound → 404.
    def set_secret
      @secret = ::Secrets::Personal::Variable
                .for(account: Current.account, organization: Current.organization)
                .find(params[:personal_secret_id])
    end
  end
end
