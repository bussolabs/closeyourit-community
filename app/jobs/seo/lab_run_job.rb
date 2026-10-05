# frozen_string_literal: true

module Seo
  # Misura la velocità di un sito con PageSpeed Insights, una strategia per volta (CYRA-539). Sito
  # sparito o messo in pausa nel frattempo → non fa niente, senza rumore.
  class LabRunJob < ApplicationJob
    queue_as :seo

    # Concorrenza UNO PER ORGANIZZAZIONE (CYRA-546), non per sito e non per installazione: la quota
    # di PageSpeed è di chi ha collegato la chiave, e serrare lì protegge quella quota al costo più
    # basso possibile. Dà anche la proprietà che serve per-sito (niente due misure sovrapposte sullo
    # stesso sito), perché i siti di una stessa organizzazione restano comunque in fila fra loro.
    #
    # La corsia UNICA di prima fermava le misure di tutti dietro a quelle di uno: finché la quota era
    # dell'installazione era il prezzo giusto, adesso sarebbe far pagare a un'organizzazione i molti
    # siti di un'altra.
    #
    # È la differenza con AuditSiteJob, che serra per SITO: quella visita il sito del cliente, e due
    # clienti diversi non si tolgono niente a vicenda.
    limits_concurrency to: 1, key: ->(site_id, _strategy) { Seo::LabRunJob.lane_for(site_id) }

    # Il sito sparito NON finisce nella corsia comune di tutti: `"seo:lab:"` senza coda metterebbe
    # ogni job orfano in fila con chiunque altro. Con l'id del sito resta solo in fila con sé stesso,
    # ed esce comunque subito perché il sito non c'è.
    def self.lane_for(site_id)
      organization_id = Seo::Site.joins(:project).where(id: site_id).pick("projects.organization_id")
      "seo:lab:#{organization_id || site_id}"
    end

    def perform(site_id, strategy)
      site = Seo::Site.enabled.find_by(id: site_id)
      return if site.nil?

      Seo::MeasureLab.call(site:, strategy:)
    end
  end
end
