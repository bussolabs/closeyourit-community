module Slack
  # Events of the Puckies' Slack app (CYRA-1019). Machine endpoint: the gate is Slack's signature;
  # the work runs in a job because Slack wants an answer within three seconds.
  class EventsController < ActionController::API
    def create
      body = request.raw_post
      verified = Coworkers::Slack.verified?(timestamp: request.headers["X-Slack-Request-Timestamp"],
                                            signature: request.headers["X-Slack-Signature"], body: body)
      return head :not_found unless verified

      payload = JSON.parse(body)
      return render(json: { challenge: payload["challenge"] }) if payload["type"] == "url_verification"
      # The first delivery was already queued: Slack retries only when an answer came late.
      return head :ok if request.headers["X-Slack-Retry-Num"].present?

      Coworkers::SlackEventJob.perform_later(payload.slice("team_id", "event_id", "event")) if payload["type"] == "event_callback"
      head :ok
    rescue JSON::ParserError
      head :ok
    end
  end
end
