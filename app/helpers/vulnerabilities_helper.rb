# frozen_string_literal: true

# Colori della sezione Vulnerabilità (CYRA-506). Il colore è semantico, non decorativo: rosso solo
# per ciò che va guardato adesso, così un elenco pieno di rosso significa davvero un problema.
module VulnerabilitiesHelper
  SEVERITY_COLORS = {
    "critical" => :red,
    "high" => :orange,
    "moderate" => :amber,
    "low" => :sky,
    "unknown" => :gray
  }.freeze

  RUNTIME_STATE_COLORS = {
    "eol" => :red,
    "ending_soon" => :amber,
    "supported" => :emerald
  }.freeze

  def vulnerability_severity_color(severity) = SEVERITY_COLORS.fetch(severity.to_s, :gray)

  def runtime_state_color(state) = RUNTIME_STATE_COLORS.fetch(state.to_s, :gray)

  # I file che l'ultima scansione non ha letto, nominati uno per uno (CYRA-810). Il progetto sta
  # davanti al path perché l'elenco è cross-progetto: «Gemfile.lock» da solo non dice di chi è.
  # Oltre l'anteprima il resto diventa un numero: un monorepo rotto non deve riempire la testata.
  def unverified_manifests_summary(manifests, total)
    named = manifests.map { |manifest| "#{manifest.project.key} · #{manifest.path}" }
    rest = total - manifests.size
    return named.join(", ") if rest <= 0

    named.push(t("member.monitoring.vulnerabilities.unverified.more", count: rest)).join(", ")
  end
end
