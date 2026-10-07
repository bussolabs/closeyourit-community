module Coworkers
  # What the runtime asks Rails while a task drives a browser (CYRA-1015, CYRA-1016, CYRA-1028): the
  # login of a site (only the worker sees it), the person's actions while they hold the screen, and
  # the latest screen or the proof video. Never offered to the model as a tool.
  module Session
    OPS = %w[site_secret control attach].freeze
    MAX_SCREEN = 2.megabytes
    MAX_VIDEO = 12.megabytes
    MAGIC = { "screen" => "\xFF\xD8\xFF".b, "video" => "\x1A\x45\xDF\xA3".b }.freeze

    def self.call(run, op, args)
      raise Tools::UnknownCall unless OPS.include?(op) && run.reload.active? && run.kind == "task"

      args = args.is_a?(Hash) ? args.stringify_keys : {}
      case op
      when "site_secret" then secret(run, args["domain"])
      when "control" then control(run, Array(args["done"]).map(&:to_s))
      else attach(run, args["kind"].to_s, args["data"].to_s, args["url"].to_s)
      end
    end

    def self.secret(run, domain)
      site = run.puck.sites.find_by(domain: domain.to_s.downcase)
      site ? { values: site.placeholders } : { error: "unknown_site" }
    end

    # The person's queued clicks and text for the worker to replay; replayed ones are marked done.
    def self.control(run, done)
      run.with_lock do
        run.update!(control_steps: run.control_steps.map { |step| done.include?(step["id"]) ? step.merge("done" => true) : step })
      end
      { control: run.control, steps: run.control_steps.reject { |step| step["done"] }.first(10) }
    end

    def self.attach(run, kind, data, url)
      bytes = Base64.strict_decode64(data)
      limit = kind == "video" ? MAX_VIDEO : MAX_SCREEN
      return { error: "invalid_attachment" } unless MAGIC.key?(kind) && bytes.start_with?(MAGIC[kind]) && bytes.bytesize <= limit

      if kind == "video"
        run.video.attach(io: StringIO.new(bytes), filename: "proof-#{run.id}.webm", content_type: "video/webm")
      else
        run.screen.attach(io: StringIO.new(bytes), filename: "screen.jpg", content_type: "image/jpeg")
        run.update!(runtime_state: run.runtime_state.merge("screen_url" => url.first(500)))
      end
      run.publish
      { status: "attached" }
    rescue ArgumentError
      { error: "invalid_attachment" }
    end
    private_class_method :secret, :control, :attach
  end
end
