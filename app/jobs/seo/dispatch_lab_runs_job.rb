# frozen_string_literal: true

module Seo
  # Dispatcher ricorrente delle misure di velocità (CYRA-539): due per sito scaduto, telefono e
  # computer. Gira ogni ora, ma la cadenza vera la decide il sito con `next_lab_run_at`.
  #
  # Due uscite silenziose, entrambe volute, e da CYRA-546 entrambe PER ORGANIZZAZIONE:
  #
  # - **Senza collegamento** i siti di quell'organizzazione non vengono accodati affatto, e il giro
  #   logga UN solo avviso per tutte. Scrivere una riga fallita per ogni sito ogni ora riempirebbe la
  #   storia dei controlli con una configurazione mancante, e la storia serve a vedere i guasti del
  #   sito. Un avviso per organizzazione, invece, sarebbe di nuovo rumore proporzionale al numero di
  #   organizzazioni: chi legge il log deve sapere che è successo, non riceverne una copia per ognuna.
  # - **A quota esaurita** si fermano i soli siti di CHI ha esaurito la propria, finché il suo
  #   interruttore in cache non scade. Le altre organizzazioni pagano con un'altra chiave e la loro
  #   quota è intatta: fermarle sarebbe spegnere una funzione che avevano pagato.
  class DispatchLabRunsJob < ApplicationJob
    queue_as :maintenance

    def perform
      @connected = {}
      @exhausted = {}
      disconnected = Set.new

      # `includes(:project)`: l'organizzazione si legge dal progetto per ogni sito, e senza il
      # preload sarebbe una query per sito — la forma esatta che Prosopite ferma nei test.
      Seo::Site.due_for_lab_run.includes(:project).find_each do |site|
        organization_id = site.project.organization_id
        next disconnected << organization_id unless connected?(organization_id)
        next if quota_exhausted?(organization_id)

        Seo::LabRun.strategies.each_key { |strategy| Seo::LabRunJob.perform_later(site.id, strategy) }
      end

      log_not_connected(disconnected) if disconnected.any?
    end

    private

    # Memoizzato con `fetch`, non con `||=`: un `false` memoizzato con `||=` si rileggerebbe a ogni
    # sito, cioè proprio nel caso — l'organizzazione senza collegamento — che qui si vuole pagare una
    # volta sola.
    def connected?(organization_id)
      @connected.fetch(organization_id) do
        @connected[organization_id] =
          Integrations::Resolve.connected?(organization: organization_id, provider: :pagespeed)
      end
    end

    def quota_exhausted?(organization_id)
      @exhausted.fetch(organization_id) do
        @exhausted[organization_id] =
          Rails.cache.read(Seo::PageSpeed::Constants.quota_exhausted_key(organization_id)).present?
      end
    end

    def log_not_connected(organizations)
      Rails.logger.warn("[seo] misure di velocità saltate: #{organizations.size} organizzazioni " \
                        "non hanno collegato il servizio che le misura")
      nil
    end
  end
end
