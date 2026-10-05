# frozen_string_literal: true

# Un rilievo SEO sul canale CLI. La lista è cross-progetto, quindi il progetto esce per esteso
# (id+key+name) e non come solo id: senza la key servirebbe una seconda chiamata per ogni riga.
#
# `evidence` esce così com'è: è la prova, e riassumerla qui costringerebbe chi legge dalla riga di
# comando ad aprire la pagina per sapere cosa è stato trovato davvero.
class SeoIssueSerializer < ApplicationSerializer
  attributes :id, :check_key, :evidence, :triage_note, :first_seen_at, :last_seen_at, :ticket_id

  attribute(:severity) { |issue| issue.severity }
  attribute(:status) { |issue| issue.status }
  attribute(:area) { |issue| issue.area }
  attribute(:label) { |issue| issue.label }
  attribute(:url) { |issue| issue.url }
  attribute(:promoted) { |issue| issue.promoted? }

  attribute(:project) do |issue|
    { id: issue.project.id, key: issue.project.key, name: issue.project.name }
  end

  attribute(:site) do |issue|
    { id: issue.site_id, base_url: issue.site.base_url, environment: issue.site.environment.label }
  end
end
