# frozen_string_literal: true

module Cli
  module V1
    # Regole di alerting (org-level) dell'organizzazione del token. TUTTE le azioni (incluse index/show)
    # gated da `alerts.manage` (org-level, NO scope) — specchio del canale Member, che non ha una chiave
    # `alerts.view` e gata anche la lettura con `alerts.manage`; coerente con alert_channels#index (già
    # gatato). Anti-BOLA: scope org via Current.organization.alerting_rules → un id di un'altra org dà R404
    # (RecordNotFound centralizzato). La logica vive nel service condiviso Alerting::Rules::Save; qui solo
    # il parsing dell'input del canale (throttle_minutes→throttle_seconds) e la serializzazione.
    class AlertRulesController < Cli::V1::BaseController
      before_action :require_alerts_management
      before_action :set_rule, only: %i[show update destroy]

      def index
        records, meta = paginate(Current.organization.alerting_rules.with_visible_measurements(visible_projects).ordered)
        render_ok(AlertRuleSerializer.new(records), meta: meta)
      end

      def show
        render_ok(AlertRuleSerializer.new(@rule))
      end

      def create
        rule = Current.organization.alerting_rules.new
        result = Alerting::Rules::Save.call(rule:, organization: Current.organization,
                                            attributes: rule_attributes, actor: Current.account)
        if result.ok?
          render_created(AlertRuleSerializer.new(result.value))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def update
        result = Alerting::Rules::Save.call(rule: @rule, organization: Current.organization,
                                            attributes: rule_attributes, actor: Current.account)
        if result.ok?
          render_ok(AlertRuleSerializer.new(@rule))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        @rule.destroy
        render_no_content
      end

      private

      # Anti-BOLA: solo regole della propria org (id di un'altra org → RecordNotFound → R404).
      def set_rule
        @rule = Current.organization.alerting_rules.with_visible_measurements(visible_projects).find(params[:id])
      end

      # Il canale parsa (minuti→secondi), il service persiste. throttle_minutes è il valore del canale;
      # throttle_seconds è il campo canonico del model. CYCL-62: qui NON si normalizza blank→nil come fa
      # il Member — una chiave assente su Parameters legge nil, quindi `[]=` la aggiungeva e ogni update
      # parziale azzerava scope, livello e soglia. Chi vuole azzerare manda il campo vuoto: blank→nil lo
      # fanno il cast di AR e `scoped_id`.
      def rule_attributes
        permitted = params.permit(:name, :event_type, :min_level, :threshold_ms, :threshold,
                                  :throttle_minutes, :enabled, :project_id, :environment_id,
                                  :measurement_series_id, channel_ids: [],
                                  measurement_config: %i[version statistic comparison threshold window_seconds quantile])
        minutes = permitted.delete(:throttle_minutes)
        permitted[:throttle_seconds] = [ minutes.to_i, 1 ].max * 60 if minutes.present?
        permitted
      end

      def require_alerts_management
        require_permission!("alerts.manage")
      end
    end
  end
end
