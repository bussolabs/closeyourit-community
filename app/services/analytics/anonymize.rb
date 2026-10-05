# frozen_string_literal: true

module Analytics
  # BOUNDARY PII dell'ingest pageview: dentro entrano i segnali identificanti raw (IP, User-Agent),
  # fuori escono SOLO fatti anonimi (visitor_hash, browser, os, bot). Va chiamato INLINE nel
  # controller, PRIMA dell'enqueue: gli argomenti dei job Solid Queue vengono persistiti su Postgres,
  # quindi passare IP/UA a un job equivarrebbe a salvarli. IP e UA muoiono qui.
  #
  # visitor_hash = SHA-256(salt-giornaliero-UTC \x1f ip \x1f user_agent \x1f project_id):
  # - salt ruotato ogni giorno e distrutto dopo ANALYTICS_SALT_RETENTION_DAYS → hash storici
  #   irreversibili (nessun consenso tecnico necessario, stile Plausible);
  # - project_id nell'input → nessuna correlazione dello stesso visitatore cross-progetto.
  class Anonymize < ApplicationService
    Identity = Data.define(:visitor_hash, :browser, :os, :bot, :device_type, :browser_version, :os_version)

    SEPARATOR = "\x1f"

    def initialize(ip:, user_agent:, project_id:)
      @ip = ip
      @user_agent = user_agent
      @project_id = project_id
    end

    def call
      device = Analytics::Device.parse(@user_agent)
      if device.bot
        return Result.ok(Identity.new(
          visitor_hash: nil, browser: nil, os: nil, bot: true,
          device_type: nil, browser_version: nil, os_version: nil
        ))
      end

      digest = Digest::SHA256.hexdigest(
        [ Analytics::Salt.current.value, @ip, @user_agent, @project_id ].join(SEPARATOR)
      )
      Result.ok(Identity.new(
        visitor_hash: digest, browser: device.browser, os: device.os, bot: false,
        device_type: device.device_type, browser_version: device.browser_version, os_version: device.os_version
      ))
    end
  end
end
