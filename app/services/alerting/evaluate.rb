# frozen_string_literal: true

module Alerting
  # Cuore della pipeline: dato un evento (errore/uptime), trova le regole che matchano, calcola i
  # destinatari (Recipients ∩ preferenze) e consegna in-app + email con throttle/dedup. Idempotente e
  # difensiva: subject/project spariti → no-op. The result counts personal deliveries only;
  # queued external attempts are not successful deliveries. CYRA-1227
  class Evaluate < ApplicationService
    def self.call(...) = new(...).call

    def initialize(event_type:, subject_type:, subject_id:, project_id:,
                   environment: nil, environment_id: nil, level: nil, duration_ms: nil,
                   organization_id: nil, value: nil, handled: nil, actor_id: nil, at: Time.current, rule_id: nil,
                   metric: nil, breach: nil, above: nil, decision: nil)
      @rule_id = rule_id
      @metric = metric.to_s.presence     # measurement back under threshold (server_threshold_recovered)
      @breach = breach.to_s.presence     # identity of a threshold crossing/return: stands in for the time bucket
      @above = above                     # threshold the open breach already alerted: only higher rules fire
      @decision = decision               # expired ignore decision, frozen when the finding reopened (CYRA-1144)
      @event_type = event_type.to_s
      @subject_type = subject_type
      @subject_id = subject_id
      @project_id = project_id
      @environment = environment        # stringa (eventi errore)
      @environment_id = environment_id  # uuid (eventi uptime)
      @level = level
      @duration_ms = duration_ms        # durata del campione (eventi metric_threshold)
      @organization_id = organization_id # eventi org-scoped senza progetto (server_*)
      @value = value                     # valore misurato (eventi soglia server_cpu/mem/disk/temp)
      @handled = handled                 # mechanism.handled dell'evento errore (gate unhandled_only)
      @actor_id = actor_id               # attore dell'evento da escludere dai destinatari (idea_*, CYRA-147)
      @at = at
    end

    def call
      return Result.ok(0) if subject.nil?

      # A recovery updates the Slack messages of its alert even when no rule announces it (CYRA-1156).
      Alerting::SlackRecovery.call(event_type: @event_type, subject: subject, at: @at)
      organization, rules, recipients = resolve_scope
      return Result.ok(0) if organization.nil? || rules.empty?

      # Contenuto snapshottato nella lingua del DESTINATARIO (title/body finiscono congelati nella riga
      # Alerting::Notification): memoizzato per locale — max |LOCALES| render, non uno per destinatario.
      # I canali esterni (webhook Slack/Discord) non hanno un account → lingua di default.
      content_for = Hash.new do |cache, locale|
        cache[locale] = I18n.with_locale(locale) { Alerting::Content.for(event_type: @event_type, subject: subject, **content_context) }
      end

      delivered = 0
      rules.each do |rule|
        next if @event_type == "measurement_threshold" && !Measurements::Dispatch.current?(subject, rule.reload)
        recipients.each do |account|
          next if @actor_id && account.id == @actor_id # l'attore non si auto-notifica (idea_*, CYRA-147)

          delivered += deliver_to(rule, account, subject, content_for[account.effective_locale], organization)
        end
        # Platform alerts never reach an organization's shared webhooks (CYRA-875).
        next if Alerting::PlatformAlert.event_type?(@event_type)

        deliver_channels(rule, subject, content_for[I18n.default_locale])
      end
      Result.ok(delivered)
    end

    private

    # Subject dell'evento (Errors::Group / Uptime::Incident / Metrics::Group …), memoizzato: usato per
    # lo snapshot del contenuto e — sui metric_threshold — per il gate subtype-aware (count_based?).
    def subject
      @subject ||= @subject_type.constantize.find_by(id: @subject_id)
    end

    def deliver_to(rule, account, subject, content, organization)
      pref = Alerting::Preference.for(account: account, organization: organization)
      channels = pref.channels_for(@event_type, connected_telegram: account.connected_telegram?)

      count = 0
      count += deliver_in_app(rule, account, subject, content) # in-app SEMPRE (non disattivabile)
      telegram = deliver_telegram(rule, account, subject, content, channels[:telegram])
      unless ::Notifications::Deliver.reached_by_telegram?(telegram)
        count += deliver_email(rule, account, subject, content, pref, channels[:email])
      end
      count + (telegram&.ok? ? 1 : 0)
    end

    def deliver_in_app(rule, account, subject, content)
      result = Alerting::Deliver.in_app(
        rule: rule, account: account, event_type: @event_type, subject: subject,
        content: content, dedup_key: dedup_key(rule, account, "in_app")
      )
      result.ok? ? 1 : 0
    end

    def deliver_email(rule, account, subject, content, pref, decision)
      return 0 unless decision[:deliver]

      result = Alerting::Deliver.email(
        rule: rule, account: account, event_type: @event_type, subject: subject,
        content: content, dedup_key: dedup_key(rule, account, "email"),
        quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
      )
      result.ok? ? 1 : 0
    end

    # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail.
    def deliver_telegram(rule, account, subject, content, decision)
      return unless decision[:deliver]

      Alerting::Deliver.telegram(
        rule: rule, account: account, event_type: @event_type, subject: subject,
        content: content, dedup_key: dedup_key(rule, account, "telegram"), bucket: decision[:bucket]
      )
    end

    # Reserve once per window; external I/O runs on dedicated workers. CYRA-1227
    def deliver_channels(rule, subject, content)
      rule.channels.enabled.sum do |channel|
        identity = @event_type == "measurement_threshold" ? "#{rule.id}:#{dedup_subject}" : dedup_subject
        key = "alerting:channel:#{channel.id}:#{@event_type}:#{identity}:#{throttle_bucket(rule)}"
        window_expires_at = rule.throttle_seconds.seconds.from_now
        token = ChannelReservation.acquire(channel:, key:, expires_in: rule.throttle_seconds)
        next 0 unless token

        enqueue_channel(rule, channel, subject, content, key, token, window_expires_at) ? 1 : 0
      end
    end

    # Snapshot project labels too; destination changes cancel queued events rather than reroute them.
    # The window's end travels with the job: an attempt that starts after it sends nothing. CYRA-1227
    def enqueue_channel(rule, channel, subject, content, throttle_key, reservation_token, window_expires_at)
      job = Alerting::DeliverChannelJob.perform_later(
        channel_id: channel.id, rule_id: rule.id, organization_id: rule.organization_id,
        link_id: Alerting::RuleChannel.find_by!(rule_id: rule.id, channel_id: channel.id).id,
        destination_digest: Digest::SHA256.hexdigest(channel.target),
        event_type: @event_type, subject_type: subject.class.name, subject_id: subject.id,
        content: { title: content.title, body: content.body, url: content.url,
                   project: content.project&.attributes&.slice("id", "key", "name")&.symbolize_keys },
        occurred_at: @at, throttle_key:, reservation_token:, window_expires_at:, metric: @metric,
        delivery_id: SecureRandom.uuid
      )
      ChannelReservation.release(channel_id: channel.id, key: throttle_key, token: reservation_token) unless job
      job
    rescue StandardError
      ChannelReservation.release(channel_id: channel.id, key: throttle_key, token: reservation_token)
      raise
    end

    # Il bucket nel dedup_key implementa il throttle: stesso (account, canale, evento, subject) nella
    # stessa finestra → stessa key → bloccato dall'unique [rule_id, dedup_key].
    def dedup_key(rule, account, via)
      "#{account.id}:#{via}:#{@event_type}:#{dedup_subject}:#{throttle_bucket(rule)}"
    end

    # CYRA-1256 — a threshold crossing or return is already a state change remembered on the host:
    # its own identity stands in for the time window, so a new crossing a minute after a return is
    # not swallowed by the previous one's bucket, while a retried job still collides with itself.
    def throttle_bucket(rule)
      @breach || (@at.to_i / rule.throttle_seconds)
    end

    # Chiave stabile del subject per il throttle. Gli errori/uptime/server deduplicano sul subject
    # (gruppo, incident, host): un burst sullo stesso subject → una notifica. I log sono uno stream
    # append-only — ogni Logs::Entry è un subject NUOVO, quindi l'id per-entry non deduplicherebbe
    # nulla; si throttla per (progetto, livello) così un'ondata di log error/fatal non genera una
    # notifica per riga (CYRA-55).
    def dedup_subject
      return "measurement:#{subject.series_id}" if @event_type == "measurement_threshold"
      return "#{@subject_id}:#{@metric}" if threshold_recovery?
      return @subject_id unless @event_type == "log_alert"

      "logs:#{@project_id}:#{@level}"
    end

    # Risolve (organization, rules, recipients) per il tipo di evento: gli eventi org-scoped (server_* e
    # agents_*) non hanno progetto, tutti gli altri passano dal progetto.
    def resolve_scope
      if @project_id.nil? && @organization_id.present?
        organization = Organizations::Organization.find_by(id: @organization_id)
        return [ nil, [], [] ] if organization.nil?

        [ organization, matching_org_rules(organization), org_recipients(organization).to_a ]
      else
        project = Projects::Project.find_by(id: @project_id)
        return [ nil, [], [] ] if project.nil?

        [ project.organization, matching_rules(project), project_recipients(project) ]
      end
    end

    # Destinatari di un evento project-scoped. Gli accessi ai segreti (CYRA-77) vanno a chi RISPONDE
    # del vault, non a chiunque veda il progetto: «qualcuno ha letto la chiave di produzione» è un
    # fatto di sicurezza, e la lista è la stessa dell'approvazione a due. Tutti gli altri eventi
    # (errori, uptime, idee…) restano a chi vede il progetto, come sempre.
    def project_recipients(project)
      return Alerting::Recipients.for_secrets(project: project).to_a if @event_type.start_with?("secret_")

      Alerting::Recipients.for(project: project).to_a
    end

    # Recipients of org-scoped events: CloseYourIt's own services to the gods only (CYRA-875), workload
    # deadlines to the action's participants (CYRA-147), agent alarms to whoever runs automation
    # (agents.view/manage), the rest (server_*) to whoever sees the fleet (servers.view/manage).
    def org_recipients(organization)
      if Alerting::PlatformAlert.event_type?(@event_type)
        Alerting::PlatformAlert.recipients(organization)
      elsif @event_type.start_with?("workload_")
        workload_recipients(organization)
      elsif @event_type.start_with?("agents_")
        Alerting::Recipients.for_agents(organization: organization)
      else
        Alerting::Recipients.for_servers(organization: organization)
      end
    end

    # Destinatari di un avviso di scadenza workload: i partecipanti della action (il subject), non tutta
    # l'org — l'action è team-scoped. subject è già garantito non-nil (guard a inizio #call).
    # Difesa in profondità come Alerting::Recipients#account_ids (CYRA-241): l'intersezione con le
    # membership VIVE dell'org scarta chi è stato rimosso lasciando dietro una partecipazione residua —
    # senza, un ex membro continuerebbe a ricevere le scadenze del team.
    def workload_recipients(organization)
      return [] unless subject.respond_to?(:participants)

      members = Connections::Membership.where(organization_id: organization.id).select(:account_id)
      subject.participants.where(id: members).to_a
    end

    def matching_rules(project)
      if @event_type == "measurement_threshold"
        return [] unless @rule_id && subject.is_a?(Alerting::Evaluation) && subject.project_id == project.id && subject.rule_id == @rule_id && subject.status == "firing"
        return Alerting::Rule.notifying.where(id: @rule_id, organization_id: project.organization_id,
          project_id: project.id, event_type: @event_type, measurement_series_id: subject.series_id).to_a
      end
      # CYRA-478: `notifying`, non `enabled` — una regola silenziata a tempo resta attiva ma non
      # notifica finché non scade il silenzio.
      Alerting::Rule.notifying
                    .where(organization_id: project.organization_id, event_type: @event_type)
                    .where("project_id IS NULL OR project_id = ?", project.id)
                    .includes(:environment)
                    .select { |rule| environment_match?(rule) && level_match?(rule) && threshold_match?(rule) && unhandled_match?(rule) }
    end

    # Gate "solo non-gestiti" (CYRA-49): una regola errore con unhandled_only scatta SOLO quando
    # l'evento è un crash non gestito (mechanism.handled=false). handled=true (cattura volontaria) o nil
    # (sconosciuto, es. capture_message) → nessun match: la regola dei crash veri non deve rumoreggiare.
    # Non-error o regola normale → sempre passante.
    def unhandled_match?(rule)
      return true unless rule.error_event? && rule.unhandled_only?

      @handled == false
    end

    # Regole degli eventi org-scoped (server_* e agents_*): org-level puro — project/environment della
    # regola non si applicano (host e agenti non appartengono a un progetto). Filtro soglia sul valore
    # misurato (nessuna soglia per agents_* → sempre passante).
    def matching_org_rules(organization)
      return threshold_recovery_rules(organization) if threshold_recovery?

      Alerting::Rule.notifying
                    .where(organization_id: organization.id, event_type: @event_type)
                    .where.not(id: excluded_rule_ids)
                    .select { |rule| server_threshold_match?(rule) }
    end

    # CYRA-1256 — the return under threshold reaches the rules of its measurement, whatever their
    # threshold: the people and channels told about the crossing hear that it is over.
    def threshold_recovery_rules(organization)
      return [] unless Alerting::Rule::THRESHOLD_EVENT_TYPES.include?(@metric)

      Alerting::Rule.notifying
                    .where(organization_id: organization.id, event_type: @metric)
                    .where.not(threshold: nil)
                    .where.not(id: excluded_rule_ids)
                    .to_a
    end

    def threshold_recovery? = @event_type == "server_threshold_recovered"

    def content_context
      return { metric: @metric, value: @value } if threshold_recovery?
      return { decision: @decision } if @decision

      {}
    end

    # CYRA-519 — regole silenziate su QUESTA macchina: restano accese per tutte le altre. Un evento
    # che non riguarda una macchina non ha eccezioni da applicare, e la query non parte nemmeno.
    def excluded_rule_ids
      host = subject_host
      return [] if host.nil?

      Alerting::RuleHostExclusion.where(host_id: host.id).select(:rule_id)
    end

    # La macchina dell'evento: il subject stesso per i server_*, oppure quella a cui appartiene
    # (un campione, un container). Se il subject non porta a una macchina, non c'è nulla da escludere.
    def subject_host
      return subject if subject.is_a?(Servers::Host)
      return nil unless subject.respond_to?(:host)

      subject.host
    end

    # Soglia delle regole server_cpu/mem/disk/temp: scatta se il valore misurato raggiunge la soglia
    # EFFETTIVA. Regola senza soglia (down/up/failed) → sempre. Senza valore → conservativo, no.
    def server_threshold_match?(rule)
      return true if rule.threshold.nil?
      return false if @value.nil?

      threshold = effective_threshold(rule).to_f
      return false if @above && threshold <= @above.to_f # rule already told about this breach (CYRA-1256)

      @value.to_f >= threshold
    end

    # CYRA-458: la soglia per-macchina (impostata sull'host per quella metrica) sostituisce quella della
    # regola org — una macchina con la sua soglia è giudicata con quella, non col metro generale, e l'avviso
    # scatta sullo stesso limite che l'UI mostra accanto al valore. Host senza override → soglia della regola.
    def effective_threshold(rule)
      override = subject.threshold_for(rule.event_type) if subject.is_a?(Servers::Host)
      override || rule.threshold
    end

    def environment_match?(rule)
      return true if rule.environment_id.nil?
      return rule.environment_id == @environment_id if @environment_id.present?
      return false if @environment.blank?

      # simplecov:disable FK environment_id on_delete: :nullify → environment_id presente ⇒ environment presente;
      # il ramo `rule.environment&` (nil) è irraggiungibile (un env cancellato azzera environment_id → esce a monte).
      rule.environment&.code.to_s.casecmp?(@environment.to_s)
      # simplecov:enable
    end

    def level_match?(rule)
      return true unless rule.error_event? || rule.log_event?
      return true if rule.min_level.nil?
      return false if @level.nil?

      @level >= rule.min_level
    end

    # Soglia delle regole metric_threshold. Semantica per subtype (CYRA-39):
    # - verdetti "a conteggio" (repeated_http/rebuild_storm/high_query_count → Metrics::Group#count_based?):
    #   pesano per numero di occorrenze, non per durata (il campione ha duration_ms=0). La soglia
    #   occorrenze è già applicata a monte (Metrics::Ingest::Record#notify_alerts) → il gate di durata
    #   non si applica, l'alert passa.
    # - verdetti duration-based: scattano solo se il campione dura almeno threshold_ms; senza durata
    #   nell'evento → conservativo, no alert.
    # Per il filtro event_type in matching_rules, qui il subject è sempre un Metrics::Group.
    # CYRA-1214: un gruppo ignorato dopo l'accodamento non avvisa — subject è letto all'invio, lo
    # stato è quello corrente.
    def threshold_match?(rule)
      return true unless rule.event_metric_threshold?
      return false if subject.is_a?(Metrics::Group) && subject.status_ignored?
      return true if subject.count_based?
      return true if rule.threshold_ms.nil?
      return false if @duration_ms.nil?

      @duration_ms.to_f >= rule.threshold_ms.to_f
    end
  end
end
