# frozen_string_literal: true

module Analytics
  # Parser User-Agent minimale in-house: nomi + versione major di browser/OS e device_type per il
  # breakdown della dashboard (niente modelli/gem con database di regex). L'ordine dei match è
  # SIGNIFICATIVO: Edge si spaccia per Chrome, Chrome per Safari, iPad/iPhone contengono "like Mac
  # OS X" → Edge prima di Chrome, Chrome prima di Safari, iOS prima di macOS.
  class Device
    Parsed = Data.define(:browser, :os, :bot, :device_type, :browser_version, :os_version)

    # Crawler/bot/headless: pageview scartati a monte (202 accepted:0). UA vuoto = nessun browser
    # reale → trattato come bot.
    BOT = /bot|crawler|spider|crawling|headless|lighthouse|slurp|curl|wget|python-requests|phantomjs|puppeteer|playwright/i

    # [nome, detect, version] — version cattura la major (Safari usa Version/X, non Safari/604).
    BROWSERS = [
      [ "Edge", /Edg(?:e|A|iOS)?\//, /Edg(?:e|A|iOS)?\/(\d+)/ ],
      [ "Opera", /OPR\/|Opera/, %r{OPR/(\d+)} ],
      [ "Firefox", %r{Firefox/|FxiOS/}, %r{(?:Firefox|FxiOS)/(\d+)} ],
      [ "Chrome", %r{Chrome/|CriOS/}, %r{(?:Chrome|CriOS)/(\d+)} ],
      [ "Safari", %r{Safari/}, %r{Version/(\d+)} ]
    ].freeze

    # macOS cattura major.minor (10.15); gli altri OS la sola major.
    OSES = [
      [ "iOS", /iPhone|iPad|iPod/, /OS (\d+)[._]/ ],
      [ "Android", /Android/, /Android (\d+)/ ],
      [ "Windows", /Windows/, /Windows NT (\d+)/ ],
      [ "macOS", /Macintosh|Mac OS X/, /Mac OS X (\d+)[._](\d+)/ ],
      [ "Linux", /Linux|X11/, nil ]
    ].freeze

    def self.parse(user_agent)
      ua = user_agent.to_s
      if ua.blank? || BOT.match?(ua)
        return Parsed.new(browser: nil, os: nil, bot: true, device_type: nil, browser_version: nil, os_version: nil)
      end

      browser, browser_version = match_with_version(BROWSERS, ua)
      os, os_version = match_with_version(OSES, ua)
      Parsed.new(
        browser: browser, os: os, bot: false,
        device_type: device_type(ua), browser_version: browser_version, os_version: os_version
      )
    end

    # Primo match della tabella (ordine significativo). La version è la concatenazione dei gruppi
    # catturati (major, o major.minor per macOS); nil se il pattern non cattura nulla.
    def self.match_with_version(table, user_agent)
      table.each do |name, detect, version_re|
        next unless detect.match?(user_agent)

        version = nil
        if version_re && (m = user_agent.match(version_re))
          version = m.captures.compact.join(".").presence
        end
        return [ name, version ]
      end
      [ nil, nil ]
    end
    private_class_method :match_with_version

    # iPad/Android-senza-Mobile = tablet; iPhone/iPod/Android-Mobile/"Mobile" = mobile; resto desktop.
    def self.device_type(user_agent)
      return "tablet" if /iPad/.match?(user_agent)
      return "mobile" if /iPhone|iPod/.match?(user_agent)
      return /Mobile/.match?(user_agent) ? "mobile" : "tablet" if /Android/.match?(user_agent)
      return "mobile" if /Mobile/.match?(user_agent)

      "desktop"
    end
    private_class_method :device_type
  end
end
