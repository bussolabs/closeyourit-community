# frozen_string_literal: true

module Seo
  # Visita un sito e ne registra l'esito. Sito sparito o messo in pausa nel frattempo → non fa
  # niente, senza rumore.
  class AuditSiteJob < ApplicationJob
    queue_as :seo

    # Un solo giro alla volta per sito: la visita dura minuti e il dispatcher ri-accoda ogni ora,
    # quindi due giri sullo stesso sito potrebbero sovrapporsi — e si contenderebbero le stesse
    # righe di pagine e rilievi, aprendo e chiudendo gli stessi problemi a vicenda. Stessa
    # protezione di Uptime::CheckJob, per la stessa ragione. Siti diversi restano paralleli.
    limits_concurrency to: 1, key: ->(site_id) { "seo:audit:#{site_id}" }

    def perform(site_id)
      site = Seo::Site.enabled.find_by(id: site_id)
      return if site.nil?

      Seo::AuditSite.call(site:)
    end
  end
end
