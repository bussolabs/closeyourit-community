# frozen_string_literal: true

module Connections
  # Join progetto ↔ environment: dichiara su quali environment un progetto riceve ingest.
  # Integrità tenant: l'environment deve appartenere alla stessa org del progetto.
  class ProjectEnvironment < ApplicationRecord
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :project_environments
    belongs_to :environment,
               class_name: "Types::Environment",
               inverse_of: :project_environments

    validates :environment_id, uniqueness: { scope: :project_id }
    validate :environment_matches_project_organization

    CAPABILITIES = %w[servers uptime secrets approval].freeze
    # Colonna DB per ogni capability: le prime 3 seguono la convenzione "#{cap}_enabled". "approval" fa
    # eccezione — la colonna (condivisa col default su Types::Environment) si chiama "approval_required"
    # per leggibilità nel form/CLI (CYRA-138, Fase 4 pezzo C1a), quindi il predicato risolto è
    # #approval_required? e non #approval_enabled?. Mappa esplicita invece di derivare il nome per
    # interpolazione: nessuna sorpresa quando una capability futura non segue lo schema "_enabled".
    CAPABILITY_COLUMNS = {
      "servers" => :servers_enabled,
      "uptime" => :uptime_enabled,
      "secrets" => :secrets_enabled,
      "approval" => :approval_required
    }.freeze
    # Wire tri-state dei canali (Member switch / CLI) → colonna override:
    # "inherit" → nil (eredita il default dell'ambiente), "on" → true, "off" → false.
    TRISTATE = { "inherit" => nil, "on" => true, "off" => false }.freeze

    # Estrae dai parametri di un canale l'hash { colonna_override => valore } da applicare alla riga
    # join. Due forme (adattamento del canale, logica condivisa qui):
    #   singola   { capability: "servers", value: "on" }        → switch UI, una capability per volta
    #   multipla  { "servers" => "on", "uptime" => "inherit" }  → CLI, più capability insieme
    # Ignora capability sconosciute e value fuori da inherit|on|off (nessun update silenzioso errato);
    # le chiavi non fornite non finiscono nell'hash (così la CLI tocca solo i flag passati).
    def self.capability_overrides(source)
      pairs =
        if source[:capability].present?
          [ [ source[:capability].to_s, source[:value] ] ]
        else
          CAPABILITIES.map { |cap| [ cap, source[cap] ] }
        end
      pairs.each_with_object({}) do |(cap, value), acc|
        next unless CAPABILITIES.include?(cap) && TRISTATE.key?(value.to_s)

        acc[CAPABILITY_COLUMNS.fetch(cap)] = TRISTATE[value.to_s]
      end
    end

    # Capability risolte per la coppia [progetto, ambiente] (tri-state):
    # override esplicito (true/false) sulla riga join batte il default; nil = eredita il default
    # dell'ambiente (Types::Environment). Si legge SEMPRE la colonna raw (self[:col]), mai il predicato,
    # per non ricorrere sull'override che porta lo stesso nome.
    def servers_enabled?   = resolve(:servers_enabled)
    def uptime_enabled?    = resolve(:uptime_enabled)
    def secrets_enabled?   = resolve(:secrets_enabled)
    def approval_required? = resolve(:approval_required)

    private

    def resolve(attr)
      override = self[attr]
      override.nil? ? environment.public_send("#{attr}?") : override
    end

    def environment_matches_project_organization
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) if environment.organization_id != project.organization_id
    end
  end
end
