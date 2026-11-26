module Slack
  # Button clicks on the alerts posted by the Slack app (CYRA-1156). Same gate as the events: Slack's
  # signature over the raw body; the work runs in a job because Slack wants an answer within three seconds.
  class InteractionsController < ActionController::API
    def create
      body = request.raw_post
      verified = Coworkers::Slack.verified?(timestamp: request.headers["X-Slack-Request-Timestamp"],
                                            signature: request.headers["X-Slack-Signature"], body: body)
      return head :not_found unless verified

      click = click_from(JSON.parse(Rack::Utils.parse_query(body)["payload"].to_s))
      Alerting::SlackActionJob.perform_later(click) if click
      head :ok
    rescue JSON::ParserError
      head :ok
    end

    private

    # Only our three buttons: the link buttons open a page in the browser and need nothing from us.
    def click_from(payload)
      action = Array(payload["actions"]).first || {}
      return nil unless payload["type"] == "block_actions" && Alerting::SlackAction::ACTIONS.include?(action["action_id"])

      { "team_id" => payload.dig("team", "id") || payload.dig("user", "team_id"), "user_id" => payload.dig("user", "id"),
        "channel" => payload.dig("container", "channel_id") || payload.dig("channel", "id"),
        "ts" => payload.dig("container", "message_ts") || payload.dig("message", "ts"),
        "action" => action["action_id"], "action_ts" => action["action_ts"] }
    end
  end
end
