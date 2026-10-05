# frozen_string_literal: true

module Member
  # Regole di alerting (org-level). CRUD gated da alerts.manage. Controller flat per non ombreggiare
  # il namespace di dominio ::Alerting (vedi routes).
  class AlertingRulesController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted). last_fired = MAX subquery sulle
    # notifiche della regola (stessa fonte del valore in riga); NULLS LAST copre i mai-scattati.
    SORT_COLUMNS = {
      "rule" => "LOWER(alerting_rules.name)",
      "event" => :event_type,
      "throttle" => :throttle_seconds,
      "last_fired" => "(SELECT MAX(n.created_at) FROM alerting_notifications n " \
                      "WHERE n.rule_id = alerting_rules.id)",
      # CYRA-478 — ordinare per rumore: gli scatti dell'ultimo giorno e dell'ultima settimana, contati
      # in sottoquery così l'ordinamento vale su TUTTE le regole e non solo su quelle in pagina.
      "fired_24h" => "(SELECT COUNT(*) FROM alerting_notifications n WHERE n.rule_id = alerting_rules.id " \
                     "AND n.created_at >= NOW() - INTERVAL '24 hours')",
      "fired_7d" => "(SELECT COUNT(*) FROM alerting_notifications n WHERE n.rule_id = alerting_rules.id " \
                    "AND n.created_at >= NOW() - INTERVAL '7 days')",
      "status" => :enabled
    }.freeze

    before_action :require_manage
    before_action :set_rule, only: %i[show edit update destroy]
    before_action :measurement_destination, only: %i[new show edit]
    before_action :load_form_data, only: %i[new create edit update]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :event_type, :q, :sort, only: :index

    def index
      base = Current.organization.alerting_rules.with_visible_measurements(visible.projects)
      @active_count = base.enabled.count
      @off_count = base.where(enabled: false).count
      notifications = Current.organization.alerting_notifications
      @triggered_count = notifications.where.not(event_type: :measurement_threshold)
        .or(notifications.where(project_id: visible.projects.select(:id))).where(created_at: 24.hours.ago..).count

      scope = base.includes(:project, :environment).ordered
      scope = scope.where(event_type: event_filter) if event_filter.any?
      scope = scope.where("alerting_rules.name ILIKE :q", q: "%#{search_q}%") if search_q.present?
      scope = scope.where(project_id: project_filter) if project_filter.any?
      @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @rules = @pagination.records
      @last_fired = Alerting::Notification.where(rule_id: @rules.map(&:id))
                                          .group(:rule_id).maximum(:created_at)
      # CYRA-478 — quante volte ciascuna regola è scattata nell'ultimo giorno e nell'ultima settimana.
      # Due conteggi aggregati sulle notifiche già scritte, NON un contatore mantenuto al dispatch: il
      # dispatch è il percorso caldo degli avvisi e non deve pagare una scrittura in più per una
      # colonna di elenco. Il costo qui è due GROUP BY sulle sole regole in pagina.
      rule_ids = @rules.map(&:id)
      @fired_24h = Alerting::Notification.where(rule_id: rule_ids, created_at: 24.hours.ago..).group(:rule_id).count
      @fired_7d = Alerting::Notification.where(rule_id: rule_ids, created_at: 7.days.ago..).group(:rule_id).count
      # La soglia del "rumoroso": chi sta sopra si vede a colpo d'occhio senza dover leggere i numeri
      # uno per uno. È relativa alla pagina, non assoluta: un'organizzazione tranquilla non deve
      # vedersi accendere tutto, e una rumorosa non deve vedere tutto spento.
      @noisy_threshold = Alerting::Rule::NOISY_SHARE * (@fired_24h.values.sum.nonzero? || 1)
    end

    # CYRA-476: la pagina della regola (read-only). Elenca le entità che sorveglia oggi + i canali, così
    # si capisce se un dato sito è coperto senza aprire altre pagine.
    # CYRA-490: + la condizione scritta in una frase (Sentence, generata dai campi) e lo storico degli
    # scatti (Triggers: conteggi come l'index + elenco recente), così la regola si giudica senza aprirla
    # in modifica e senza interpretare i campi di un modulo.
    def show
      @coverage = Alerting::Coverage.entities_for(@rule)
      @sentence = Alerting::Rules::Sentence.call(@rule)
      @trigger_stats = Alerting::Rules::Triggers.stats(@rule)
      @recent_triggers = Alerting::Rules::Triggers.recent(@rule)
    end

    def new
      # event_type prefillato dal link "Crea la regola" delle index cron/uptime (CYRA-477): il form
      # apre già sull'evento scoperto. Valore fuori enum ignorato → form pulito.
      # CYRA-476: il pannello "Chi viene avvisato" del detail di un monitor passa anche progetto+ambiente
      # → la regola nasce già mirata a quel sito scoperto. Valori non visibili/non dell'org ignorati.
      # CYRA-482 — niente evento di default: il form si apriva su "Nuovo errore", un evento di error
      # monitoring, anche arrivandoci dallo spazio infrastruttura. Senza un prefill esplicito, chi
      # compila sceglie, invece di dover disfare una scelta che non ha preso.
      @templates = ::Alerting::Rules::Templates.all
      @rule = Current.organization.alerting_rules.new(throttle_seconds: 300, enabled: true,
                                                      event_type: prefill_event_type,
                                                      project_id: prefill_project_id,
                                                      environment_id: prefill_environment_id)
    end

    # CYRA-482 — applica un modello pronto. I modelli a due eventi (caduta e ritorno di un sito)
    # creano ENTRAMBE le regole in una transazione: metà coppia è il guasto che il ticket descrive —
    # sai quando il sito cade e non sai mai quando è tornato. Cosa verrà creato è scritto sulla card
    # PRIMA che si confermi.
    def apply_template
      template = ::Alerting::Rules::Templates.find(params[:template])
      return redirect_to(new_member_alerting_rule_path, alert: t("member.alerting.rules.templates.unknown")) if template.nil?

      created = []
      ActiveRecord::Base.transaction do
        template.event_types.each do |event_type|
          rule = Current.organization.alerting_rules.new
          result = ::Alerting::Rules::Save.call(
            rule: rule, organization: Current.organization, actor: Current.account,
            attributes: { name: ::Notifications::Catalog.entry(event_type)&.title || event_type,
                          event_type: event_type,
                          throttle_seconds: template.throttle_minutes * 60,
                          enabled: true,
                          # Gli stessi filtri del form (CYRA-483, dopo il review): un id di progetto
                          # che chi crea NON vede non deve entrare nella regola. Save azzera già gli
                          # id di un'altra organizzazione, ma dentro la propria org la visibilità è
                          # per-progetto e il gate sta qui, come per il prefill.
                          project_id: prefill_project_id,
                          environment_id: prefill_environment_id }.compact
          )
          raise ActiveRecord::Rollback if result.err?

          created << rule
        end
      end

      if created.size == template.event_types.size
        redirect_to member_alerting_rules_path,
                    notice: t("member.alerting.rules.templates.created", count: created.size)
      else
        redirect_to new_member_alerting_rule_path, alert: t("member.alerting.rules.templates.failed")
      end
    end

    def create
      # `new` viene reso anche da qui quando la validazione fallisce: i modelli pronti devono esserci
      # comunque, altrimenti la pagina esplode proprio mentre si sta correggendo un errore.
      @templates = ::Alerting::Rules::Templates.all
      @rule = Current.organization.alerting_rules.new
      result = Alerting::Rules::Save.call(rule: @rule, organization: Current.organization,
                                          attributes: rule_params, actor: Current.account)
      if result.ok?
        # CYRA-477: attivando la copertura "cron mancato", i job già fermi vengono avvisati subito
        # (Scenario 3) — no-op per gli altri eventi o se la regola è disabilitata.
        Crons::AlertActiveMissed.call(organization: Current.organization, rule: @rule)
        redirect_to member_alerting_rules_path, notice: t("member.alerting.rules.created")
      else
        @errors = @rule.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      result = Alerting::Rules::Save.call(rule: @rule, organization: Current.organization,
                                          attributes: rule_params, actor: Current.account)
      if result.ok?
        redirect_to member_alerting_rules_path, notice: t("member.alerting.rules.updated")
      else
        @errors = @rule.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @rule.destroy
      redirect_to member_alerting_rules_path, notice: t("member.alerting.rules.deleted")
    end

    private

    # Anti-BOLA: solo regole della propria org.
    def set_rule
      @rule = Current.organization.alerting_rules.with_visible_measurements(visible.projects).find(params[:id])
    end

    def measurement_destination
      if action_name == "new" && params[:event_type] == "measurement_threshold"
        redirect_to new_member_monitoring_measurement_rule_path(params.permit(:project_id, :measurement_series_id).to_h)
      elsif @rule&.event_measurement_threshold?
        redirect_to(action_name == "edit" ? edit_member_monitoring_measurement_rule_path(@rule) : member_monitoring_measurement_rule_path(@rule))
      end
    end

    def load_form_data
      @channels = Current.organization.alerting_channels.order(:name)
      @projects = visible.projects.order(:name)
      @environments = Current.organization.environments.order(:position, :label)
      # CYRA-465 — la temperatura è proponibile come evento solo se almeno una macchina della flotta
      # la riporta: senza sensori in tutta l'org sarebbe una regola che non potrà mai scattare. Il form
      # tiene comunque l'evento di una regola già esistente su server_temp, per non alterarla in modifica.
      @temperature_reported = ::Servers::Sample.temperature_reported?(Current.organization)
    end

    def rule_params
      permitted = params.permit(:name, :event_type, :min_level, :threshold_ms, :threshold,
                                :throttle_minutes, :enabled, :unhandled_only, :project_id, :environment_id,
                                :measurement_series_id, channel_ids: [],
                                measurement_config: %i[version statistic comparison threshold window_seconds quantile])
      minutes = permitted.delete(:throttle_minutes)
      permitted[:throttle_seconds] = [ minutes.to_i, 1 ].max * 60 if minutes.present?
      permitted[:project_id] = nil if permitted[:project_id].blank?
      permitted[:environment_id] = nil if permitted[:environment_id].blank?
      permitted[:min_level] = nil if permitted[:min_level].blank?
      permitted[:threshold_ms] = nil if permitted[:threshold_ms].blank?
      permitted[:threshold] = nil if permitted[:threshold].blank?
      permitted
    end

    def require_manage
      require_permission!("alerts.manage")
    end

    # event_type di partenza per il form (link dalle index): solo se è un valore valido dell'enum.
    def prefill_event_type
      type = params[:event_type].to_s
      type if Alerting::Rule.event_types.key?(type)
    end

    # Progetto/ambiente di partenza (link dal detail di un monitor, CYRA-476): solo se davvero visibili
    # e dell'org — un id estraneo viene semplicemente ignorato, il form resta "tutti i progetti".
    def prefill_project_id
      id = params[:project_id].presence
      id if id && visible.projects.exists?(id:)
    end

    def prefill_environment_id
      id = params[:environment_id].presence
      id if id && Current.organization.environments.exists?(id:)
    end

    def search_q = params[:q].to_s.strip
    def event_filter = Array(params[:event_type]).reject(&:blank?)
    def project_filter = Array(params[:project_id]).reject(&:blank?)
  end
end
