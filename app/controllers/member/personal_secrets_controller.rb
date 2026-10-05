# frozen_string_literal: true

module Member
  # Vault PERSONALE di variabili d'ambiente cifrate (gemello per-utente del vault di progetto Secrets::).
  # Struttura FLAT (niente matrice ambiente): un unico set { nome => valore } per utente, scoped
  # [account, organization]. Dati POSSEDUTI dall'utente → NESSUNA permission key (ownership come Todos):
  # lo scope .for(account, org) è anche anti-BOLA per find/destroy. Controller flat (non Member::Secrets::*)
  # per non ombreggiare il namespace ::Secrets (model).
  class PersonalSecretsController < Member::BaseController
    permission_not_required "Cassaforte personale: i segreti sono dell'utente e nessuna chiave di progetto li " \
                            "riguarda."

    RECENT_EVENTS = 15

    def index
      load_secrets
    end

    # Rivela il valore in chiaro di un secret personale SOLO su richiesta esplicita (CYRA-204): la lista
    # non rende più i valori nel sorgente HTML (li leggerebbe chi apre il sorgente, senza mostrare né
    # lasciare traccia). Il valore viaggia verso il client solo qui e l'accesso è registrato nell'audit
    # ("read", source web) — gemello del reveal del vault di progetto (CYRA-202). Anti-BOLA: owned_secrets
    # è già scoped [account, org], un id di un altro utente/altra org → RecordNotFound → 404.
    def reveal
      variable = owned_secrets.find(params[:id])
      ::Secrets::Personal::RecordEvent.call(action: "read", account: Current.account,
                                            organization: Current.organization,
                                            name: variable.name, metadata: { count: 1, source: "web" })
      # Il valore in chiaro non deve persistere nella cache HTTP del browser (disco/memoria).
      response.headers["Cache-Control"] = "no-store"
      render json: { value: variable.value }
    end

    # Upsert di una variabile: la riga-crea e il Salva di una riga esistente postano entrambi qui
    # (Set fa find_or_initialize per [account, org, nome]).
    def create
      result = ::Secrets::Personal::Variables::Set.call(
        account: Current.account, organization: Current.organization,
        name: params[:name].to_s, value: params[:value].to_s, description: params[:description]
      )

      if result.ok?
        redirect_to member_personal_secrets_path, notice: t("member.personal_secrets.saved")
      else
        @row_errors = result.error.details || { base: [ result.error.message ] }
        @open_row = params[:name].to_s
        load_secrets
        render :index, status: :unprocessable_content
      end
    end

    def destroy
      variable = owned_secrets.find(params[:id])
      ::Secrets::Personal::Variables::Delete.call(variable:)
      redirect_to member_personal_secrets_path, notice: t("member.personal_secrets.deleted")
    end

    private

    # Anti-BOLA + scoping: secret di un altro account/altra org → RecordNotFound → 404.
    def owned_secrets
      ::Secrets::Personal::Variable.for(account: Current.account, organization: Current.organization)
    end

    def load_secrets
      # CYRA-684 — a pagine; i nomi COMPLETI restano a parte, servono al controllo duplicati del form.
      @pagination = paginate(owned_secrets.ordered)
      @secrets = @pagination.records
      @secret_names = owned_secrets.pluck(:name)
      @events = ::Secrets::Personal::Event.for(account: Current.account, organization: Current.organization)
                                          .recent.limit(RECENT_EVENTS).to_a
    end
  end
end
