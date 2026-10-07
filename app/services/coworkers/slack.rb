require "net/http"

module Coworkers
  # The Slack app of the Puckies (CYRA-1019): signature check, replies in threads and thread history.
  # Credentials come from the CYRA vault: SLACK_SIGNING_SECRET and SLACK_BOT_TOKEN.
  module Slack
    API = "https://slack.com/api/".freeze
    MAX_AGE = 5.minutes
    LINK_PURPOSE = "coworkers-slack-link".freeze

    def self.signing_secret = ENV["SLACK_SIGNING_SECRET"].to_s
    def self.bot_token = ENV["SLACK_BOT_TOKEN"].to_s
    def self.configured? = signing_secret.present? && bot_token.present?

    # Slack signs "v0:<timestamp>:<body>" with the app's signing secret; old timestamps are replays.
    def self.verified?(timestamp:, signature:, body:, now: Time.current)
      return false if signing_secret.blank? || timestamp.to_s !~ /\A\d+\z/
      return false if (now.to_i - timestamp.to_i).abs > MAX_AGE

      expected = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", signing_secret, "v0:#{timestamp}:#{body}")
      ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
    end

    # A short-lived code the person pastes to the bot: it ties their Slack user to this account.
    def self.link_code(account:, organization:)
      Rails.application.message_verifier(LINK_PURPOSE).generate([ account.id, organization.id ], expires_in: 15.minutes)
    end

    def self.read_link_code(code)
      Rails.application.message_verifier(LINK_PURPOSE).verified(code.to_s.strip)
    end

    def self.post(channel:, thread_ts:, text:)
      call("chat.postMessage", channel: channel, thread_ts: thread_ts, text: text.to_s.first(3900))
    end

    # The thread a mention lives in, so the Puck reads the discussion it was called into.
    def self.thread_text(channel:, thread_ts:)
      data = call("conversations.replies", channel: channel, ts: thread_ts, limit: 20)
      Array(data && data["messages"]).filter_map { |message| message["text"] if message["bot_id"].nil? }.join("\n").last(4000)
    end

    def self.call(method, body)
      return nil unless configured?

      uri = URI.join(API, method)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json; charset=utf-8", "Authorization" => "Bearer #{bot_token}")
      request.body = body.compact.to_json
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) { |http| http.request(request) }
      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[coworkers.slack] #{method} failed: #{e.class}")
      nil
    end
  end
end
