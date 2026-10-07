module Coworkers
  # The catalog of ready-made roles, read once from config/coworkers/presets.yml (CYRA-1025).
  module Presets
    Preset = Data.define(:key, :mascot, :rules)
    SAFE_DECISIONS = %w[ask deny].freeze

    def self.config = @config ||= YAML.load_file(Rails.root.join("config/coworkers/presets.yml")).freeze
    def self.version = config.fetch("version")

    def self.all
      @all ||= config.fetch("presets").map do |key, values|
        rules = values.fetch("rules", {})
        unless rules.all? { |action, decision| Assistant::Proposal.kinds.key?(action) && SAFE_DECISIONS.include?(decision) }
          raise ArgumentError, "Preset #{key} may only ask or deny known actions"
        end

        Preset.new(key: key, mascot: values.fetch("mascot"), rules: rules)
      end.freeze
    end

    def self.find(key) = all.find { |preset| preset.key == key.to_s }

    # Copies the role's rules onto the new Puck and records which role and version it came from.
    def self.apply(puck, key)
      preset = find(key)
      return if preset.nil?

      puck.preset = "#{preset.key}@#{version}"
      preset.rules.each { |action, decision| puck.rules.build(action: action, decision: decision) }
    end
  end
end
