# frozen_string_literal: true

# Sezione «Usa questo segreto» (CYRA-401): resa SEMPRE nel corpo — non in un tooltip — in fondo alle
# quattro pagine dei segreti (panoramica Vault, personali, organizzazione, progetto). Mostra il comando
# già pronto per leggere i secret dall'applicazione, con tre schede: computer / build automatiche /
# server. I comandi arrivano da Secrets::UsageSnippets, l'unico punto in cui sono definiti (così non si
# duplicano per pagina). Interpola solo nome progetto e ambiente, mai un valore.
class SecretUsageComponent < Ui::BaseComponent
  # F148 — where the page has no project in context (the Vault landing), a small form to choose
  # one, so the commands below come out filled instead of with placeholders.
  renders_one :picker

  # `collapsible: true` folds the section behind its title (a closed <details>).
  def initialize(kind:, project: nil, environment: nil, environment_codes: [], test_id: "secret-usage",
                 collapsible: false)
    @collapsible = collapsible
    @kind = kind.to_sym
    @project = project
    @environment = environment
    @environment_codes = Array(environment_codes).map(&:to_s).reject(&:blank?)
    @test_id = test_id
    @snippets = Secrets::UsageSnippets.new(kind: @kind, project: project&.key, environment: environment)
  end

  private

  attr_reader :kind, :snippets, :test_id, :environment_codes, :collapsible

  def wrapper_tag = collapsible ? :details : :section
  def header_tag = collapsible ? :summary : :div

  def header_class
    base = "flex items-center gap-2.5 px-4 py-3 border-b border-stone-200 dark:border-zinc-800"
    collapsible ? "#{base} cursor-pointer list-none group-[:not([open])]:border-b-0" : base
  end

  def personal?
    kind == :personal
  end

  def shared?
    kind == :shared
  end

  # La nota «cambia ambiente» ha senso solo dove la pagina mostra più ambienti (matrice di progetto).
  def multi_environment?
    !personal? && environment_codes.size > 1
  end
end
