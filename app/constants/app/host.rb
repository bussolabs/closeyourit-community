# frozen_string_literal: true

module App
  # The address this install answers on, for links built outside a request (emails, Telegram,
  # tokens). Read from the environment so a self-hosted install never links to closeyour.it (CYRA-916).
  module Host
    module_function

    def primary
      ENV["MAIL_HOST"].presence || ENV.fetch("APP_HOSTS", "").split(",").map(&:strip).find(&:present?) || "localhost"
    end

    def base_url = ENV["APP_BASE_URL"].presence || "https://#{primary}"
  end
end
