# frozen_string_literal: true

# CYRA-872 — resoconto settimanale dei costi dell'automazione, per fase e per progetto. Sola lettura.
# Senza settimana vale quella scorsa, da lunedì a domenica UTC:
#   bin/rails "agents:costs:weekly[<slug organizzazione>]"
#   bin/rails "agents:costs:weekly[<slug organizzazione>,2026-09-21]"
namespace :agents do
  namespace :costs do
    desc "Costi dell'automazione di una settimana, per fase e per progetto (sola lettura)"
    task :weekly, [ :organization, :week ] => :environment do |_task, args|
      organization = Organizations::Organization.find_by(slug: args[:organization].to_s)
      abort "Organizzazione non trovata: #{args[:organization].presence || '(vuota)'}" unless organization

      week = args[:week].present? ? Date.iso8601(args[:week]) : Date.current.prev_week
      puts Agents::Attempts::WeeklyCosts.call(organization:, week:).lines
    rescue Date::Error
      abort "Settimana non valida: #{args[:week]} (formato AAAA-MM-GG)"
    end
  end
end
