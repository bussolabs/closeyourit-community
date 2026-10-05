# frozen_string_literal: true

module Member
  module Monitoring
    module Servers
      # CYRA-519 — «questa regola, su questa macchina, non deve suonare». POST silenzia, DELETE
      # riattiva. Idempotenti entrambi: silenziare due volte non è un errore, e riattivare qualcosa
      # che non era silenziato nemmeno.
      #
      # Anti-BOLA su ENTRAMBI i lati: la macchina viene dallo scope dell'organizzazione corrente, e
      # la regola pure — silenziare la regola di un'altra organizzazione darebbe un 404, non un 403.
      class AlertExclusionsController < Member::BaseController
        before_action -> { require_permission!("alerts.manage") }
        before_action :set_host
        before_action :set_rule

        def create
          ::Alerting::RuleHostExclusion.find_or_create_by!(rule: @rule, host: @host)
          redirect_to member_monitoring_server_path(@host, tab: "alerts"),
                      notice: t("member.servers.alerts.muted_here", rule: @rule.name)
        end

        def destroy
          ::Alerting::RuleHostExclusion.where(rule: @rule, host: @host).destroy_all
          redirect_to member_monitoring_server_path(@host, tab: "alerts"),
                      notice: t("member.servers.alerts.unmuted_here", rule: @rule.name)
        end

        private

        def set_host
          @host = current_organization.server_hosts.find(params[:server_id])
        end

        def set_rule
          @rule = current_organization.alerting_rules.find(params[:rule_id])
        end
      end
    end
  end
end
