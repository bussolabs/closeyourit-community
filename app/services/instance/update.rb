# frozen_string_literal: true

require "json"

module Instance
  # The update of a community install as the app sees it (CYRA-1035): the newer release cached by
  # Instance::CheckReleaseJob, and the files shared with the host (see installer/closeyourit,
  # apply-update-request). The app only ever leaves a request; the host does the update.
  class Update
    class NotRequestable < StandardError; end

    CACHE_KEY = "instance/latest_release"
    HELPER_STALE_AFTER = 5.minutes
    DONE_SHOWN_FOR = 1.day

    Status = Data.define(:state, :target, :from, :backup)

    def initialize(dir: App::SelfHosted.updates_dir, current: App::Version.tag, cache: Rails.cache, now: Time.current, settings: nil)
      @dir = Pathname(dir)
      @current = current.to_s.delete_prefix("v")
      @cache = cache
      @now = now
      @settings = settings
    end

    def enabled? = App::SelfHosted.enabled?

    def current_version = @current

    # The cached release, still newer than what runs now (the cache outlives the update itself). A beta
    # left in the cache by the beta channel is never offered once the install is back on stable.
    def available
      return @available if defined?(@available)

      release = enabled? ? @cache.read(CACHE_KEY) : nil
      @available = release if release && newer?(release.version) && offered?(release.version)
    end

    # The stored verified list says the running version is insecure: what to install (CYRA-1160).
    # Never the last download, so a forged or missing list can neither raise nor hide it.
    def insecurity
      return @insecurity if defined?(@insecurity)

      @insecurity = enabled? ? settings.security_advisory_list&.finding(@current) : nil
    rescue Advisories::Invalid, KeyError, ArgumentError => e
      Rails.logger.error("Instance::Update could not read the stored security list: #{e.message}")
      @insecurity = nil
    end

    # The host writes a heartbeat every minute once `closeyourit enable updates` ran.
    def helper_alive?
      beat = @dir.join("status/heartbeat")
      beat.file? && Time.zone.at(beat.read.to_i) > @now - HELPER_STALE_AFTER
    rescue SystemCallError
      false
    end

    # :queued, :running, :done, :failed or nil. Done and failed only while they still say something.
    def state
      return :queued if request_file.exist?

      case status&.state
      when "running" then :running
      when "done" then :done if status.target == @current && status_file.mtime > @now - DONE_SHOWN_FOR
      when "failed" then :failed if status.target == available&.version
      end
    end

    def status
      return @status if defined?(@status)

      data = JSON.parse(status_file.read)
      @status = Status.new(state: data["state"].to_s, target: data["target"].to_s, from: data["from"].to_s, backup: data["backup"].to_s)
    rescue SystemCallError, JSON::ParserError
      @status = nil
    end

    def requestable? = available.present? && helper_alive? && %i[queued running].exclude?(state)

    # Written to a temporary name, then renamed: the host never reads half a request.
    def request!(actor:)
      raise NotRequestable unless requestable?

      version = available.version
      temporary = @dir.join("inbox/.request-#{SecureRandom.hex(4)}")
      temporary.write("#{version}\n")
      File.rename(temporary, request_file)
      Rails.logger.warn("Instance update to #{version} requested by account_id=#{actor.id} (running #{@current})")
      version
    end

    private

    def request_file = @dir.join("inbox/request")
    def status_file = @dir.join("status/status.json")

    def settings = @settings ||= Settings::Global.instance

    def offered?(version) = settings.release_channel == "beta" || ReleaseFeed.stable?(version)

    def newer?(version)
      !@current.match?(ReleaseFeed::VERSION_FORMAT) || Gem::Version.new(version) > Gem::Version.new(@current)
    end
  end
end
