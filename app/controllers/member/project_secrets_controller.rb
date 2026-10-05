# frozen_string_literal: true

module Member
  # Vault di variabili d'ambiente cifrate per-progetto/ambiente (fonte canonica). Tab GitHub-style
  # nella pagina progetto: MATRICE variabile × ambiente (righe = nomi, colonne = ambienti; celle
  # mascherate, mostra-valore e sblocco per riga, copy per cella), upsert per riga, delete per cella.
  # Lettura VALORI gated `secrets.read`; set/delete gated `secrets.manage`; la matrice (soli metadati)
  # si apre con l'una o con l'altra. Controller flat (non Member::Projects::*)
  # per non ombreggiare il namespace ::Projects (model). Anti-BOLA all'org visibile.
  class ProjectSecretsController < Member::BaseController
    include Member::SecretEnvironmentBoundary

    RECENT_EVENTS = 15

    before_action :set_project
    before_action :require_secrets_access, only: :index
    before_action :require_secrets_read, only: :reveal
    before_action :require_secrets_manage, only: %i[create destroy promote rotation]

    def index
      # CYRA-424 — arrivando dalla ricerca variabili (/member/vault/variables) la riga cercata va
      # evidenziata: `highlight` è il NOME della variabile su cui saltare (confronto case-insensitive
      # nella matrice, ancora `#secret-<slug>` per lo scroll). Nessun valore, solo il nome.
      @highlight = params[:highlight].to_s.strip.presence
      load_matrix
    end

    # Rivela il valore in chiaro di una cella SOLO su richiesta esplicita (CYRA-202): la matrice non
    # rende più i valori nel sorgente HTML (li leggerebbe chi apre il sorgente, senza sbloccare né
    # lasciare traccia). Il valore viaggia verso il client solo qui, dietro il gate secrets.read, e
    # l'accesso è registrato nell'audit ("read", per-cella: name + environment). Anti-BOLA: la variable
    # è risolta DENTRO lo scope del progetto (che a sua volta è già filtrato a visible.projects).
    def reveal
      variable = @project.secret_variables.find(params[:id])
      # Confine ambienti (CYRA-78): il permesso dice COSA puoi fare, questo dice DOVE. Il rifiuto è
      # JSON perché la cella si sblocca via fetch — il redirect di un form qui non lo vedrebbe nessuno.
      unless environment_allowed?(variable.environment)
        record_environment_denied(variable.environment, name: variable.name)
        return render json: { error: t("member.secrets.environment_denied") }, status: :forbidden
      end

      # `channel: "web"` (CYRA-77) accanto al `metadata.source` storico: il canale è una COLONNA
      # filtrabile e interrogabile, e su di essa passa il gate degli avvisi (una lettura dal terminale
      # non allarma nessuno, una dal browser sì). Il metadata resta per non riscrivere lo storico.
      ::Secrets::RecordEvent.call(action: "read", project: @project, environment: variable.environment,
                                  actor: Current.account, name: variable.name, channel: "web",
                                  metadata: { count: 1, source: "web" })
      # Il valore in chiaro non deve persistere nella cache HTTP del browser (disco/memoria).
      response.headers["Cache-Control"] = "no-store"
      render json: { value: variable.value }
    end

    # Salva una RIGA della matrice: un nome su N ambienti (upsert per cella). La riga-crea e il Salva di
    # una riga esistente postano entrambi qui. Ogni cella passa per Secrets::ChangeRequests::Submit
    # (CYRA-138 C1b): sugli ambienti protetti dall'approvazione a due la cella diventa una change
    # request pending invece di essere scritta — il notice riflette quante celle sono state applicate e
    # quante sono in attesa.
    def create
      name = params[:name].to_s
      # Le colonne vietate non sono nemmeno rese, ma i params arrivano dal client: una cella fuori
      # confine è un tentativo, non un errore di compilazione → 403 + audit, mai una scrittura parziale.
      forbidden = row_cells.find { |cell| !environment_allowed?(cell[:environment]) }
      return deny_environment(forbidden[:environment], name: name) if forbidden

      result = ::Secrets::Rows::Save.call(project: @project, name: name, cells: row_cells, actor: Current.account)

      if result.ok?
        redirect_to member_project_secrets_path(@project), notice: row_save_notice(result.value)
      else
        @row_errors = result.error.details || { base: [ result.error.message ] }
        @open_row = name
        load_matrix
        render :index, status: :unprocessable_content
      end
    end

    # Instrada la cancellazione attraverso Submit (CYRA-138 C1b): su un ambiente protetto NON elimina,
    # crea una change request pending. Anti-BOLA invariato (variable risolta nello scope del progetto
    # PRIMA di chiamare Submit).
    def destroy
      variable = @project.secret_variables.find(params[:id])
      name = variable.name
      return deny_environment(variable.environment, name: name) unless environment_allowed?(variable.environment)

      result = ::Secrets::ChangeRequests::Submit.call(
        project: @project, environment: variable.environment, name: name, action: :remove, actor: Current.account
      )

      notice = pending_result?(result) ? t("member.secrets.pending_approval", name: name) : t("member.secrets.deleted")
      redirect_to member_project_secrets_path(@project), notice: notice
    end

    # Copia (promote) il valore di una cella in un altro ambiente del progetto (CYRA-137, dialog di
    # conferma dalla matrice). Instrada attraverso Submit (CYRA-138 C1b): sull'ambiente target protetto
    # NON copia, crea una change request pending. L'ambiente target è risolto DENTRO
    # @project.environments.active (stesso pattern anti-injection di row_cells): un id estraneo, non
    # dichiarato o disattivato torna un alert, mai un 500. L'audit "set" resta quello già registrato da
    # Set quando applicato subito — nessun evento manuale qui.
    def promote
      variable = @project.secret_variables.find(params[:id])
      target_environment = @project.environments.active.find_by(id: params[:target_environment_id])
      # Una copia tocca DUE ambienti: legge dall'origine e scrive sulla destinazione. Il confine vale
      # su entrambi, altrimenti da un ambiente consentito si estrarrebbe (o si pianterebbe) un valore
      # di uno vietato. L'origine si controlla per prima: il suo valore non deve uscire comunque vada.
      return deny_environment(variable.environment, name: variable.name) unless environment_allowed?(variable.environment)

      if target_environment.nil?
        return redirect_to member_project_secrets_path(@project), alert: t("member.secrets.promote_invalid_target")
      end

      unless environment_allowed?(target_environment)
        return deny_environment(target_environment, name: variable.name)
      end

      if target_environment.id == variable.environment_id
        return redirect_to member_project_secrets_path(@project), alert: t("member.secrets.promote_same_environment")
      end

      result = ::Secrets::ChangeRequests::Submit.call(
        project: @project, environment: target_environment, name: variable.name,
        action: :set, value: variable.value, actor: Current.account
      )

      if result.ok?
        notice = if pending_result?(result)
          t("member.secrets.pending_approval", name: variable.name)
        else
          t("member.secrets.promoted", name: variable.name, environment: target_environment.label)
        end
        redirect_to member_project_secrets_path(@project), notice: notice
      else
        redirect_to member_project_secrets_path(@project), alert: result.error.message
      end
    end

    # Imposta/rimuove la policy di rotazione "ogni N giorni" (CYRA-138, dialog dalla matrice). Scrive
    # DIRETTAMENTE rotation_interval_days sul model (a differenza del VALORE, non passa da Set: non è
    # un cambio di plaintext, non deve toccare rotated_at/versioning/audit). Vuoto o "0" rimuove la
    # policy (nil); qualunque altro input non valido (es. negativo, se il client bypassa min="0")
    # arriva alla validazione del model e torna un alert, mai un 500.
    def rotation
      variable = @project.secret_variables.find(params[:id])
      return deny_environment(variable.environment, name: variable.name) unless environment_allowed?(variable.environment)

      raw_interval = params[:rotation_interval_days].to_s.strip
      variable.rotation_interval_days = raw_interval.blank? || raw_interval == "0" ? nil : raw_interval.to_i

      if variable.save
        notice = if variable.rotation_interval_days
          t("member.secrets.rotation_set", name: variable.name, days: variable.rotation_interval_days)
        else
          t("member.secrets.rotation_removed", name: variable.name)
        end
        redirect_to member_project_secrets_path(@project), notice: notice
      else
        redirect_to member_project_secrets_path(@project), alert: variable.errors.full_messages.to_sentence
      end
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    # secret_access / environment_allowed? / record_environment_denied vivono in
    # Member::SecretEnvironmentBoundary (CYRA-666): erano copiati qui e in altri due controller, e i due
    # nati dopo non li hanno ereditati.

    # Rifiuto dei rami che postano un form: 403 vero (non un redirect che sembrerebbe un errore di
    # compilazione) con la matrice ricaricata — che mostra i soli ambienti consentiti — e il motivo
    # in cima.
    def deny_environment(environment, name: nil)
      record_environment_denied(environment, name: name)
      flash.now[:alert] = t("member.secrets.environment_denied")
      load_matrix
      render :index, status: :forbidden
    end

    # Notice aggregato della riga (CYRA-138 C1b): se nessuna cella è in attesa il messaggio resta
    # IDENTICO a oggi ("Secret salvato.") — con l'opt-in OFF pending_count è sempre 0, quindi il flusso
    # di sempre non cambia mai. Con almeno una cella in attesa, riflette entrambi i conteggi.
    def row_save_notice(outcome)
      return t("member.secrets.saved") unless outcome.pending_count.positive?

      t("member.secrets.saved_with_pending", applied: outcome.applied_count, pending: outcome.pending_count)
    end

    # True se Submit ha messo la scrittura in attesa di approvazione invece di applicarla.
    def pending_result?(result)
      result.ok? && result.value.pending?
    end

    # Celle inviate dal form-riga, filtrate agli ambienti REALI del progetto (sicurezza subset: un
    # env_id estraneo nei params viene ignorato prima ancora della validazione model). Il service salta
    # le celle con valore blank (svuotare non cancella — il delete è esplicito per cella). La creazione
    # su un ambiente con capability secrets disabilitata è comunque bloccata dal model (on: :create).
    # Memoizzate: `create` le ispeziona per il confine ambienti prima di passarle a Rows::Save.
    def row_cells
      @row_cells ||= @project.environments.active.ordered.filter_map do |environment|
        value = params.dig(:values, environment.id.to_s)
        next if value.nil?

        # CYRA-924 — one description per name, from the dialog; the per-environment form stays for other callers.
        description = params.key?(:description) ? params[:description].to_s : params.dig(:descriptions, environment.id.to_s)
        { environment: environment, value: value.to_s, description: description }
      end
    end

    # Pivot per la matrice: righe = nomi (ordinati), colonne = ambienti attivi; cella = variabile o nil.
    # @secrets_enabled[env_id] indica se una cella VUOTA è creabile (capability risolta default+override).
    # I secret esistenti su ambienti con capability ora disabilitata restano editabili (validata on: :create).
    # `.includes(:environment)`: la resolve della capability (Connections::ProjectEnvironment#resolve)
    # carica `environment` quando l'override è nil — senza preload è 1 query per ambiente (N+1, guard
    # Prosopite bloccante sui request spec appena la matrice ha >= 2 ambienti attivi).
    def load_matrix
      caps = @project.project_environments.includes(:environment).index_by(&:environment_id)
      # Confine ambienti (CYRA-78): le colonne vietate non si rendono affatto — nascondere solo i
      # valori direbbe comunque quali ambienti esistono e quali variabili ci vivono.
      @environments = @project.environments.active.ordered.to_a.select { |e| secret_access.allowed?(e.code) }
      @secrets_enabled = @environments.to_h { |e| [ e.id, caps[e.id]&.secrets_enabled? || false ] }
      @rows = confined(@project.secret_variables.includes(:environment).to_a) { |v| v.environment_id }
        .group_by(&:name)
        .transform_values { |vars| vars.index_by(&:environment_id) }
        .sort_by(&:first)
      # Celle con una change request pending (CYRA-138 C2b): un pluck (nessun preload di attori/valori,
      # qui serve solo sapere SE la cella è in attesa, non chi/cosa) → Set di coppie [environment_id,
      # name] per lookup O(1) nel partial _cell, gemello del pattern Secrets::Drift#hole?.
      @pending_changes = @project.secret_change_requests.pending.pluck(:environment_id, :name).to_set
      @events = confined(@project.secret_events.includes(:actor, :environment).recent.limit(RECENT_EVENTS).to_a, &:environment_id)
      @delegated_secrets = confined(
        @project.shared_secret_delegations.includes(shared_value: [ :environment, :shared_variable ]).to_a
      ) { |delegation| delegation.environment&.id }
      @stats = @project.ticket_tally
      load_secret_readers
      load_consolidation_suggestions
      load_effective_matrix
    end

    # Le deleghe entrano nella stessa matrice con il nome effettivo. @rows resta locale:
    # consolidamento e modifica continuano a lavorare soltanto sulle variabili del progetto.
    def load_effective_matrix
      environment_ids = @environments.map(&:id).to_set
      @delegations_by_name = @delegated_secrets.select { |delegation| environment_ids.include?(delegation.environment.id) }
        .group_by(&:effective_name)
        .transform_values { |delegations| delegations.index_by { |delegation| delegation.environment.id } }
      local_rows = @rows.to_h.transform_values { |cells| cells.slice(*environment_ids.to_a) }.reject { |_name, cells| cells.empty? }
      names = (local_rows.keys + @delegations_by_name.keys).uniq.sort
      @matrix_total = names.size
      @local_names_count = local_rows.size
      @shared_names_count = @delegations_by_name.size
      # Una presenza delegata colma un buco locale. Le righe esclusivamente condivise
      # restano fuori dagli avvisi di drift, gestiti dall'organizzazione.
      @drift = ::Secrets::Drift.new(rows: @rows.map { |name, cells|
        [ name, cells.merge(@delegations_by_name.fetch(name, {})) ]
      }, environments: @environments)
      @secret_query = params[:q].to_s.strip
      @secret_origin = %w[local shared].include?(params[:origin]) ? params[:origin] : nil
      # The Anomalies chip filters the rows with at least one hole.
      @drift_only = params[:drift] == "1"
      @environment_counts = environment_counts(names, local_rows)
      shown = names.select { |name| matrix_row_shown?(name, local_rows) }
      @matrix_shown = shown.size
      @pagination = Pagination.from_array(shown, page: matrix_page(shown), per: requested_per(Pagination::DEFAULT_PER))
      @matrix_rows = @pagination.records.map { |name| [ name, local_rows.fetch(name, {}) ] }
    end

    # CYRA-924 — C68: the matrix pages like every list. A row reached with ?highlight= (C70), or a
    # row whose save failed, opens on the page that holds it unless the person asked for a page.
    def matrix_page(shown)
      target = @highlight.presence || @open_row.presence
      return params[:page] if params[:page].present? || target.nil?

      index = shown.index { |name| name.casecmp?(target) }
      index ? (index / requested_per(Pagination::DEFAULT_PER)) + 1 : 1
    end

    # How many names have a value (local or delegated) in each environment.
    def environment_counts(names, local_rows)
      @environments.to_h do |environment|
        [ environment.id, names.count { |name| local_rows.dig(name, environment.id) || @delegations_by_name.dig(name, environment.id) } ]
      end
    end

    def matrix_row_shown?(name, local_rows)
      return false unless name.downcase.include?(@secret_query.downcase)
      return false if @drift_only && !@drift.holes.key?(name)
      return false if @secret_origin == "local" && !local_rows.key?(name)

      @secret_origin != "shared" || @delegations_by_name.key?(name)
    end

    # CYRA-777 — le proposte di «valore in comune» che toccano QUESTO progetto: il banner in cima e
    # il segnalino sulla cella che tiene la copia. Solo a chi ha shared_secrets.manage, che è chi può
    # accettarle: agli altri sarebbe un avviso senza rimedio, e per giunta racconterebbe qualcosa dei
    # segreti di progetti che quella persona magari non vede.
    #
    # Il confronto è per COPPIA [ambiente, impronta]: lo stesso valore su due ambienti diversi sono
    # due proposte diverse, e appaiarle sulla sola impronta segnerebbe la cella sbagliata.
    def load_consolidation_suggestions
      @consolidations = []
      @consolidated_cells = {}
      return unless can?("shared_secrets.manage")

      variables = @rows.flat_map { |_name, by_env| by_env.values }.select { |v| v.value_fingerprint.present? }
      return if variables.empty?

      suggestions = ::Secrets::Consolidation::Suggestion
        .where(organization_id: @project.organization_id).status_open
        .where(environment_id: variables.map(&:environment_id).uniq,
               value_fingerprint: variables.map(&:value_fingerprint).uniq)
        .includes(:environment).index_by { |s| [ s.environment_id, s.value_fingerprint ] }
      return if suggestions.empty?

      variables.each do |variable|
        suggestion = suggestions[[ variable.environment_id, variable.value_fingerprint ]]
        @consolidated_cells[[ variable.environment_id, variable.name ]] = suggestion if suggestion
      end
      @consolidations = @consolidated_cells.values.uniq
      # La proposta può avere più nomi anche in un altro progetto: verifica l'intero
      # gruppo solo per chi può gestire i condivisi, senza leggere valori.
      @consolidation_alias_conflicts = ::Secrets::Variable
        .where(organization_id: @project.organization_id,
               environment_id: @consolidations.map(&:environment_id),
               value_fingerprint: @consolidations.map(&:value_fingerprint))
        .group(:environment_id, :value_fingerprint, :project_id)
        .having("COUNT(DISTINCT name) > 1")
        .pluck(:environment_id, :value_fingerprint, :project_id)
        .map { |environment_id, fingerprint, _project_id| [ environment_id, fingerprint ] }.to_set
    end

    # Toglie da una lista già caricata gli elementi legati a un ambiente fuori confine (CYRA-78) —
    # variabili, eventi d'audit, secret delegati: il NOME di un secret di production è già un'informazione
    # su production. Chi non ha restrizioni non paga niente: la lista torna identica, senza nemmeno
    # scorrerla (ed è per questo che il comportamento storico resta bit-identico, ambienti disattivati
    # compresi). Un elemento senza ambiente (eventi bundle-level) resta sempre visibile.
    def confined(records)
      return records unless secret_access.restricted?

      allowed_ids = @environments.map(&:id).to_set
      records.select do |record|
        environment_id = yield(record)
        environment_id.nil? || allowed_ids.include?(environment_id)
      end
    end

    # CYRA-422 — pannello «Chi può vedere questi segreti»: le membership reali con secrets.read/manage
    # sul progetto (stesso OR del gate reveal). I NOMI sono una rassicurazione riservata a chi gestisce i
    # membri o i segreti; agli altri, per non far trapelare la composizione dell'organizzazione, resta il
    # solo conteggio. Secrets::Readers risolve in batch (niente resolver per-account → niente N+1 nel render).
    def load_secret_readers
      @secret_readers = ::Secrets::Readers.for_project(@project)
      @secret_readers_reveal = can?("members.view") || can?("secrets.manage", scope: @project)
      @secret_readers_permissions_href = member_members_path if can?("members.view")
    end


    # CYRA-721 — due gate distinti, perché sono due domande diverse.
    #
    # `require_secrets_access` apre la MATRICE: nomi delle variabili, ambienti, stato. Sono metadati,
    # non valori (dal CYRA-202 il valore non è più nel sorgente), e servono tanto a chi legge quanto a
    # chi gestisce: senza, chi ha solo `secrets.manage` non avrebbe nessuna pagina da cui gestire.
    #
    # `require_secrets_read` apre il VALORE in chiaro e vuole `secrets.read` e basta. Prima accettava
    # anche `secrets.manage` ("manage implica read") e il risultato era il contrario di quello che le
    # due chiavi promettono: chi poteva solo gestire leggeva tutto, e il permesso di sola lettura non
    # aveva nessun comando per mostrare il valore. Poter cambiare un valore non è poterlo vedere.
    #
    # Deny → redirect+alert come require_permission! (che non gestisce l'OR).
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
  end
end
