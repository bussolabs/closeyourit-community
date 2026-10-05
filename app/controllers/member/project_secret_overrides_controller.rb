# frozen_string_literal: true

module Member
  # Valori personali dei secret di progetto (CYRA-79): chi gestisce il vault assegna a una persona un
  # valore diverso dal default, e quella persona se lo ritrova con `cyi run` senza fare nulla.
  # admin-provisioned: si scrive solo da qui (gate `secrets.manage`), mai dall'interessato — chi riceve
  # l'override non ha alcun modo di darselo, cambiarlo o toglierselo.
  #
  # Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects (model),
  # stesso motivo di ProjectSecretsController. Anti-BOLA: progetto risolto nei soli progetti visibili,
  # override risolto DENTRO il progetto, destinatario scelto tra chi quei secret li può già leggere.
  class ProjectSecretOverridesController < Member::BaseController
    include Member::SecretEnvironmentBoundary

    before_action :set_project
    before_action :require_secrets_manage

    # CYRA-924 — every column but the actions sorts (C9); the list is filtered in Ruby, so it sorts there.
    SORT_COLUMNS = {
      "recipient" => ->(override) { override.account.name.to_s.downcase },
      "environment" => ->(override) { override.environment.label.to_s.downcase },
      "name" => ->(override) { override.name.to_s.downcase },
      "assigned" => ->(override) { override.created_at }
    }.freeze

    def index
      load_page
    end

    def new
      load_form
    end

    def create
      environment = @project.environments.active.find_by(id: params[:environment_id])
      # Ambiente inesistente, non dichiarato o disattivato = campo compilato male → il form torna
      # indietro col motivo.
      return reject_form(t("member.secret_overrides.invalid_environment")) if environment.nil?
      # Ambiente che invece esiste ma sta FUORI dal confine di chi opera: non è un errore di
      # compilazione, è un tentativo (CYRA-78) — audit + 403, come su ogni altro ramo del vault.
      # Confonderlo col caso sopra lascerebbe bussare a production senza lasciare traccia.
      return deny_environment(environment, name: params[:name]) unless environment_allowed?(environment)

      result = ::Secrets::Overrides::Set.call(
        project: @project, environment: environment, account: recipient,
        name: params[:name], value: params[:value], description: params[:description],
        actor: Current.account
      )

      if result.ok?
        redirect_to member_project_secret_overrides_path(@project),
                    notice: t("member.secret_overrides.saved", name: result.value.name)
      else
        reject_form(result.error.message)
      end
    end

    def destroy
      override = @project.secret_overrides.find(params[:id])
      # Il confine ambienti vale anche in cancellazione: un admin ristretto non tocca gli override di un
      # ambiente che non può vedere (li avrebbe già fuori dalla lista).
      return deny_environment(override.environment, name: override.name) unless environment_allowed?(override.environment)

      result = ::Secrets::Overrides::Delete.call(override: override, actor: Current.account)
      # Mai un notice di riuscita su una cancellazione fallita: la riga sarebbe ancora lì e la persona
      # continuerebbe a ricevere il valore su misura, credendo di averglielo tolto.
      notice_or_alert = if result.ok?
        { notice: t("member.secret_overrides.deleted", name: override.name) }
      else
        { alert: result.error.message }
      end
      redirect_to member_project_secret_overrides_path(@project), **notice_or_alert
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_secrets_manage
      require_permission!("secrets.manage", scope: @project)
    end

    # Confine ambienti dell'attore su QUESTO progetto (CYRA-78): stessa policy della matrice.


    # Gli ambienti su cui si può assegnare: dichiarati, attivi e dentro il confine di chi sta operando.
    def allowed_environments
      @allowed_environments ||= @project.environments.active.ordered.to_a.select { |e| environment_allowed?(e) }
    end

    # I destinatari possibili: le persone che i secret di questo progetto li possono già LEGGERE
    # (stesso elenco del pannello «Chi può vedere questi segreti»). Assegnare a chiunque altro
    # lascerebbe una riga che sembra attiva e non lo è: il valore personale si vede solo passando dal
    # gate di lettura.
    def readers
      @readers ||= ::Secrets::Readers.for_project(@project)
    end

    # Il destinatario indicato dal form, risolto DENTRO i lettori: un account_id estraneo (altra org,
    # persona senza accesso) diventa nil e il service lo rifiuta con un messaggio solo, sempre lo stesso.
    def recipient
      readers.find { |reader| reader.account.id == params[:account_id] }&.account
    end

    def load_page
      # Confinati agli ambienti consentiti: il NOME di un override su production è già un'informazione
      # su production, come per le variabili (CYRA-78).
      @overrides = @project.secret_overrides
                           .includes(:account, :environment, :created_by)
                           .ordered
                           .to_a
                           .select { |override| environment_allowed?(override.environment) }
      @overrides = sorted_rows(@overrides, columns: SORT_COLUMNS)
      @recipients_count = @overrides.map(&:account_id).uniq.size
      @stats = @project.ticket_tally
    end

    def load_form
      @environments = allowed_environments
      @readers = readers
      # I nomi già nel vault per gli ambienti consentiti: l'override quasi sempre sostituisce un
      # default esistente, e battere a mano un nome UPPER_SNAKE è il modo più facile per sbagliarlo.
      @known_names = @project.secret_variables
                             .where(environment: @environments)
                             .distinct
                             .order(:name)
                             .pluck(:name)
      @stats = @project.ticket_tally
    end

    # Form rifiutato: 422 con il motivo in cima e i campi ricaricati (mai un redirect, che sembrerebbe
    # un'operazione riuscita).
    def reject_form(message)
      flash.now[:alert] = message
      load_form
      render :new, status: :unprocessable_content
    end

    # Il tentativo bloccato dal confine ambienti finisce PRIMA nell'audit, poi il 403 (CYRA-78).
    def deny_environment(environment, name: nil)
      ::Secrets::RecordEvent.call(action: "denied", project: @project, environment: environment,
                                  actor: Current.account, name: name.presence, channel: "web")
      flash.now[:alert] = t("member.secrets.environment_denied")
      load_page
      render :index, status: :forbidden
    end
  end
end
