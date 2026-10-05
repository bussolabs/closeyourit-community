# frozen_string_literal: true

module Member
  module AlertingRules
    # Silenzia una regola per un tempo scelto (CYRA-478). Non la spegne: `enabled` resta com'è, la
    # regola continua a valutare e a comparire nei conteggi — semplicemente non notifica fino alla
    # scadenza. Sono due gesti diversi e devono restare due comandi diversi: chi silenzia per un'ora
    # non deve ritrovarsi una regola disattivata per sempre.
    class MutesController < Member::BaseController
      # Le durate offerte: un'ora per il picco di adesso, un giorno per la giornata storta, una
      # settimana per il lavoro in corso. Un valore fuori elenco non silenzia niente.
      DURATIONS = { "1" => 1.hour, "24" => 1.day, "168" => 1.week }.freeze

      before_action :require_manage
      before_action :set_rule

      def update
        duration = DURATIONS[params[:hours].to_s]
        return redirect_back_to_rules(alert: t("member.alerting.rules.mute_invalid")) if duration.nil?

        @rule.update!(muted_until: Time.current + duration)
        redirect_back_to_rules(notice: t("member.alerting.rules.muted_notice",
                                         time: l(@rule.muted_until, format: :short)))
      end

      def destroy
        @rule.update!(muted_until: nil)
        redirect_back_to_rules(notice: t("member.alerting.rules.unmuted_notice"))
      end

      private

      def set_rule
        @rule = Current.organization.alerting_rules.with_visible_measurements(visible.projects).find(params[:rule_id])
      end

      def require_manage = require_permission!("alerts.manage")

      def redirect_back_to_rules(**flash_options)
        redirect_back fallback_location: member_alerting_rule_path(@rule), **flash_options
      end
    end
  end
end
