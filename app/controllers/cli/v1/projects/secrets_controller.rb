# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Vault dei secret per-progetto/ambiente da terminale (cyi secrets/run). Thin adapter sui service
      # Secrets::* condivisi col canale Member. Anti-BOLA via set_project! (progetto non visibile → R404
      # PRIMA di ogni gate). Lettura VALORI gated `secrets.read`; set/delete gated `secrets.manage`;
      # la lista dei soli NOMI si apre con l'una o con l'altra (CYRA-721: manage NON implica più read).
      # I nomi sono UPPER_SNAKE; il valore è cifrato at-rest.
      class SecretsController < Cli::V1::BaseController
        # Riconosce un UUID nel path param :id; altrimenti :id è trattato come NAME del secret.
        UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

        before_action :set_project!

        # GET .../secrets[?environment=<code|uuid>] — metadati (mai i valori). Env opzionale = filtro.
        def index
          return unless require_secrets_access

          scope = @project.secret_variables.includes(:environment).ordered
          if environment_ref.present?
            env = resolve_environment! or return

            scope = scope.where(environment: env)
          elsif secret_access.restricted?
            # Attore con restrizione env: la lista non mostra nemmeno i nomi degli env vietati.
            scope = scope.where(environment_id: allowed_environment_ids)
          end

          records, meta = paginate(scope)
          render_ok(SecretVariableSerializer.new(records), meta:)
        end

        # GET .../secrets/bundle?environment=<code|uuid> — mappa decifrata { NAME => value }.
        def bundle
          return unless require_secrets_read

          env = resolve_environment! or return

          # `account:` = CHI legge (CYRA-79): sopra i default si applicano gli override personali di
          # questo account. Si arriva qui solo dopo il gate secrets.read e dopo resolve_environment!,
          # che ha già fatto valere il confine ambienti — un override non è una scorciatoia per leggere
          # un ambiente vietato.
          result = ::Secrets::Bundle.call(project: @project, environment: env, account: Current.account)
          # Audit: la lettura programmatica dei VALORI (cyi bundle/download/run) è tracciata. `channel`
          # (CYRA-77) dice che è arrivata dal terminale: senza, il registro non distingue un download
          # automatico in pipeline da una persona che apre una cella nel browser.
          ::Secrets::RecordEvent.call(action: "read", project: @project, environment: env,
                                      actor: Current.account, channel: "cli",
                                      metadata: { count: result.value.size })
          render_ok(result.value)
        end

        # GET .../secrets/:id/value[?environment=<code|uuid>] — il valore in chiaro di UN SOLO secret.
        # :id = UUID (l'ambiente lo dice il secret) oppure NAME (serve ?environment=), come su destroy.
        # Esiste per l'audit (CYRA-77): `cyi secrets get` filtrava il bundle lato client, quindi il
        # registro vedeva una lettura dell'intero ambiente e non sapeva DIRE quale valore fosse uscito.
        # Il valore lo serve ::Secrets::Bundle e non la singola Secrets::Variable, perché il download
        # completo consegna anche i nomi delegati dallo shared e gli scostamenti personali (CYRA-79):
        # leggerne uno solo non può dare un valore diverso da quello che si otterrebbe scaricandoli tutti.
        def value
          return unless require_secrets_read

          target = resolve_named_secret!
          return if target.nil?

          name, env = target
          bundle = ::Secrets::Bundle.call(project: @project, environment: env, account: Current.account)
          plaintext = bundle.value[name]
          if plaintext.nil?
            return render_error("R404-SECRET-001", "Secret inesistente", status: :not_found)
          end

          ::Secrets::RecordEvent.call(action: "read", project: @project, environment: env,
                                      actor: Current.account, name: name, channel: "cli",
                                      metadata: { count: 1 })
          render_ok({ name: name, value: plaintext })
        end

        # POST .../secrets — upsert { environment, name, value, description? }. Instradato via
        # Secrets::ChangeRequests::Submit (CYRA-230): su un ambiente protetto dall'approvazione a due NON
        # scrive, accoda una change request pending (202) invece di applicare (201).
        def create
          return unless require_secrets_manage

          env = resolve_environment! or return

          result = ::Secrets::ChangeRequests::Submit.call(
            project: @project, environment: env, action: :set,
            name: params[:name], value: params[:value], description: params[:description],
            actor: Current.account
          )

          unless result.ok?
            return render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          end

          submitted = result.value
          return render_change_request_accepted(submitted.change_request) if submitted.pending?

          # CYRA-777 — «questo valore ce l'hanno anche altri»: un conteggio e un indirizzo, mai i nomi
          # dei progetti. Sta in `meta` e non in `data` perché non è un campo del secret appena
          # scritto: è una cosa vera del vault, che il comando stampa dopo la conferma di scrittura.
          notice = ::Secrets::Consolidation::Notice.call(variable: submitted.variable).value
          render_created(SecretVariableSerializer.new(submitted.variable),
                         meta: notice && { consolidation: notice.as_json })
        end

        # POST .../secrets/import — import bulk all-or-nothing { environment, variables: [{name,value,description}] }.
        def import
          return unless require_secrets_manage

          env = resolve_environment! or return

          entries = Array(params[:variables]).map do |v|
            { name: v[:name], value: v[:value], description: v[:description] }
          end
          result = ::Secrets::Variables::Import.call(project: @project, environment: env, entries: entries, actor: Current.account)

          if result.err?
            return render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          end

          # Payload sempre coi due conteggi { imported, pending }: l'ambiente è unico, quindi o tutte le
          # voci sono applicate (201) o tutte in attesa dell'approvazione a due (202, CYRA-230). Il client
          # ha comunque entrambi i numeri senza dover indovinare quale chiave è presente.
          outcome = result.value
          status = outcome.pending_count.positive? ? :accepted : :created
          render json: { data: { imported: outcome.applied_count, pending: outcome.pending_count } }, status: status
        end

        # POST .../secrets/sync — enfila il push dei secret verso GitHub. Gate: github.manage (è
        # un'operazione sull'integrazione GitHub) + secrets.read (il push scrive i VALORI del vault,
        # inclusi gli shared delegati — CYRA-234: github.manage da solo non deve poter esfiltrare i
        # secret; CYRA-721: nemmeno secrets.manage, che cambia i valori senza autorizzare a vederli) + confine environment (la sync è cross-environment: un attore ristretto non l'autorizza).
        def sync
          return unless require_permission!("github.manage", scope: @project)
          return unless require_secrets_read
          return unless require_unrestricted_environments

          repository = @project.github_repository
          return render_error("R404-GITHUB-002", "Nessun repo GitHub agganciato al progetto", status: :not_found) if repository.nil?

          preflight = ::Secrets::Github::Preflight.call(repository:)
          if preflight.err?
            # CYRA-637 — l'esito resta scritto anche quando il blocco arriva da qui. Il gemello web lo
            # fa da CYRA-106; senza, un tentativo fermato dal terminale lasciava la scheda del progetto
            # sul «riuscito» di ieri, che è il contrario di quello che è appena successo.
            repository.record_sync_failure!(preflight.error)
            return render_error(preflight.error.code, preflight.error.message,
                                status: preflight.error.status, details: preflight.error.details)
          end

          ::Secrets::Github::SyncJob.perform_later(github_repository_id: repository.id)
          render json: { data: { enqueued: true } }, status: :accepted
        end

        # DELETE .../secrets/:id — :id = UUID oppure NAME (con ?environment=). NAME senza environment
        # valido → R422 (input invalido), NON 404: così è distinguibile da "secret inesistente".
        # Instradato via Secrets::ChangeRequests::Submit (CYRA-230): su un ambiente protetto NON cancella,
        # accoda una change request pending (202). La variabile è risolta anti-BOLA PRIMA di Submit
        # (stesso pattern del canale web Member::ProjectSecretsController#destroy).
        def destroy
          return unless require_secrets_manage

          variable = find_variable! or return

          result = ::Secrets::ChangeRequests::Submit.call(
            project: @project, environment: variable.environment, action: :remove,
            name: variable.name, actor: Current.account
          )

          unless result.ok?
            return render_error(result.error.code, result.error.message, status: result.error.status)
          end

          submitted = result.value
          return render_change_request_accepted(submitted.change_request) if submitted.pending?

          render_no_content
        end

        private

        # Ramo protetto (approvazione a due attiva): la scrittura non è applicata, si accoda una change
        # request in attesa. 202 Accepted coi soli metadati della richiesta (MAI il valore proposto), così
        # il CLI distingue "applicato" (201/204) da "in attesa di approvazione" (202).
        def render_change_request_accepted(change_request)
          render json: { data: SecretChangeRequestSerializer.new(change_request).as_json }, status: :accepted
        end

        # CYRA-721 — due gate distinti, come sul canale web. `access` è per la lista dei soli NOMI
        # (metadati: chi gestisce deve sapere cosa c'è da gestire); `read` è per i VALORI in chiaro —
        # bundle, get e il push verso GitHub — e vuole `secrets.read` e basta: poter cambiare un valore
        # non è poterlo vedere, e prima l'OR con `secrets.manage` rendeva la distinzione una promessa vuota.
        def require_secrets_access
          return true if authorization.can?("secrets.read", scope: @project) ||
                         authorization.can?("secrets.manage", scope: @project)

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        def require_secrets_read
          return true if authorization.can?("secrets.read", scope: @project)

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        def require_secrets_manage
          require_permission!("secrets.manage", scope: @project)
        end

        # CYRA-234 — la sync verso GitHub spinge TUTTI gli slot mappati del repo (non filtrabile per
        # environment): un attore ristretto a un sottoinsieme di environment non può autorizzarla,
        # leggerebbe/pubblicherebbe anche gli env vietati. Nessuna restrizione → sempre ok.
        def require_unrestricted_environments
          return true unless secret_access.restricted?

          render_environment_forbidden
          false
        end

        # R403-SECRET-001: rifiuto di confine environment, IDENTICO su tutti i rami (nome via
        # resolve_environment!, UUID via find_variable!, sync cross-environment) — così il tentativo
        # fuori ambiente è indistinguibile a prescindere da come si indichi il secret. Ritorna nil.
        # Il tentativo finisce PRIMA nell'audit (CYRA-78): il 403 lo vede solo chi l'ha provato, mentre
        # chi risponde dei secret deve poter vedere che qualcuno ha bussato — e da quale canale.
        def render_environment_forbidden(environment = nil, name: nil)
          ::Secrets::RecordEvent.call(action: "denied", project: @project, environment: environment,
                                      actor: Current.account, name: name, channel: "cli")
          render_error("R403-SECRET-001", "environment non consentito per questo account", status: :forbidden)
          nil
        end

        def environment_ref = params[:environment].presence || params[:environment_id].presence

        # Risolve l'environment dentro il progetto (per code o UUID). Scoping su @project.environments =
        # nessun environment di un altro progetto/tenant può entrare.
        def resolve_environment(ref)
          ref = ref.to_s.strip
          return if ref.blank?

          @project.environments.find_by(id: ref) || @project.environments.find_by(code: ref.downcase)
        end

        # Come resolve_environment ma renderizza R422 (e ritorna nil) se assente/non dichiarato, e R403
        # se l'environment esiste ma NON è consentito all'account (restrizione env dei service account).
        def resolve_environment!
          env = resolve_environment(environment_ref)
          unless env
            render_error("R422-SECRET-001", "environment richiesto o non dichiarato dal progetto",
                         status: :unprocessable_content)
            return nil
          end

          return render_environment_forbidden(env) unless environment_allowed?(env)

          env
        end

        # Confine ambienti dell'attore su questo progetto (CYRA-78): policy condivisa col canale web,
        # con l'override per-progetto sopra la allow-list org-wide. Vale per i service account (che la
        # usano da sempre) e ora anche per gli umani via token utente. Il token d'ingest per-progetto
        # (account nil) non ha endpoint secret.
        def secret_access
          @secret_access ||= ::Secrets::EnvironmentAccess.new(account: Current.account, project: @project)
        end

        def environment_allowed?(env) = secret_access.allowed?(env&.code)

        def allowed_environment_ids
          @project.environments.where(code: secret_access.allowed_codes).ids
        end

        # Coppia [NAME, environment] da cui leggere un singolo valore (CYRA-77). Stessa grammatica di
        # find_variable! — UUID o nome — ma il risultato è un NOME, non un record: il valore può venire
        # anche da uno shared delegato o da uno scostamento personale, che non sono Secrets::Variable.
        # Ritorna nil dopo aver già renderizzato l'errore (R422 ambiente, R403 confine, 404 BOLA).
        def resolve_named_secret!
          ref = params[:id].to_s.strip
          if ref.match?(UUID_FORMAT)
            variable = @project.secret_variables.find(ref)
            return render_environment_forbidden(variable.environment, name: variable.name) unless
              environment_allowed?(variable.environment)

            return [ variable.name, variable.environment ]
          end

          env = resolve_environment! or return nil

          [ ref.upcase, env ]
        end

        # UUID → find per id nello scope progetto, poi confine environment sull'env della variabile
        # (CYRA-235: il ramo UUID saltava environment_allowed?, permettendo a un SA ristretto di
        # cancellare un secret di un env vietato indicandolo per id — l'id è nell'URL della pagina web).
        # NAME → richiede un environment valido: `resolve_environment!` rende R422 e ritorna nil se
        # manca/non dichiarato (→ distinguibile dal 404 "secret inesistente"), quindi lookup per
        # [environment, name]. Not found → RecordNotFound → 404.
        def find_variable!
          ref = params[:id].to_s.strip
          if ref.match?(UUID_FORMAT)
            variable = @project.secret_variables.find(ref)
            return variable if environment_allowed?(variable.environment)

            return render_environment_forbidden(variable.environment, name: variable.name)
          end

          env = resolve_environment! or return nil

          @project.secret_variables.find_by!(environment: env, name: ref.upcase)
        end
      end
    end
  end
end
