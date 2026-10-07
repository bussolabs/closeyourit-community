module Coworkers
  # Tells the owner of a Puck that something waits for them: in-app always, then Telegram or email
  # as their preferences say. One notice per subject and channel (CYRA-1020, CYRA-1011).
  module Notify
    def self.decision_needed(proposal)
      run = proposal.coworkers_run
      deliver(run, :puck_decision_needed, "puck_decision:#{proposal.id}", account: proposal.account) do
        [ I18n.t("member.coworkers.notify.title", name: run.puck.name),
          "#{I18n.t("member.assistant.proposals.kinds.#{proposal.kind}")}: #{proposal.payload['title'] || proposal.payload['ticket_code']}" ]
      end
    end

    def self.report_ready(run)
      deliver(run, :puck_report_ready, "puck_report:#{run.id}", account: run.requester) do
        [ I18n.t("member.coworkers.notify.report_title", name: run.puck.name), run.output.to_s.truncate(240) ]
      end
    end

    def self.deliver(run, event_type, key, account:, &content)
      # Someone who left the organization gets no more reports of its Puckies.
      return unless Connections::Membership.exists?(account_id: account.id, organization_id: run.puck.organization_id)

      preference = Alerting::Preference.for(account: account, organization: run.puck.organization)
      channels = preference.channels_for(event_type, connected_telegram: account.connected_telegram?)
      I18n.with_locale(account.effective_locale) do
        title, body = content.call
        payload = ->(via, mailer = nil) { payload(run, account, event_type, title, body, "#{key}:#{via}", mailer) }
        Notifications::Deliver.in_app(payload: payload.call("in_app"))
        telegram = (Notifications::Deliver.telegram(payload: payload.call("telegram"), bucket: channels[:telegram][:bucket]) if channels[:telegram][:deliver])
        next if Notifications::Deliver.reached_by_telegram?(telegram) || !channels[:email][:deliver]

        Notifications::Deliver.email(payload: payload.call("email", Alerting::AlertsMailer.method(:triggered)),
                                     quiet: preference.quiet_now?, bucket: channels[:email][:bucket])
      end
    end

    def self.payload(run, account, event_type, title, body, dedup_key, mailer)
      Notifications::Payload.new(
        organization: run.puck.organization, account: account, subject: run, event_type: event_type,
        title: title, body: body, url: Rails.application.routes.url_helpers.member_coworker_path(run.puck_id),
        dedup_key: dedup_key, mailer: mailer
      )
    end
    private_class_method :deliver, :payload
  end
end
