# frozen_string_literal: true

module Vulnerabilities
  module Osv
    # Dato un elenco di coordinate (ecosistema, nome, versione), ritorna quali advisory le colpiscono
    # e garantisce che ognuno esista in locale, aggiornato.
    #
    # Due passaggi, per una ragione precisa:
    # 1. `querybatch` su tutte le coordinate — magro e veloce, dice solo QUALI id guardare;
    # 2. `GET /v1/vulns/:id` solo per gli advisory che non abbiamo o che sono vecchi.
    #
    # Il secondo passaggio è quello che si paga, ed è per questo che la cache degli advisory è
    # globale: dieci progetti che usano la stessa versione di Rails scaricano quel record una volta.
    #
    # Ritorna { [ecosystem, name, version] => [Advisory, …] }. Una coordinata senza vulnerabilità NON
    # compare nella mappa.
    class Query < ApplicationService
      def initialize(coordinates:, client: Client.new, now: Time.current)
        @coordinates = Array(coordinates).uniq
        @client = client
        @now = now
      end

      def call
        return {} if @coordinates.empty?

        ids_by_coordinate = match_ids
        advisories = sync_advisories(ids_by_coordinate.values.flatten.uniq)

        ids_by_coordinate.each_with_object({}) do |(coordinate, ids), result|
          found = ids.filter_map { |id| advisories[id] }
          result[coordinate] = found if found.any?
        end
      end

      private

      # Il batch è posizionale: il risultato i-esimo appartiene alla query i-esima. Il taglio in lotti
      # serve a non spedire migliaia di coordinate in una sola richiesta (un monorepo ne produce
      # facilmente qualche migliaio).
      def match_ids
        @coordinates.each_slice(Vulnerabilities::Constants::OSV_BATCH_SIZE)
                    .each_with_object({}) do |slice, result|
          queries = slice.map { |ecosystem, name, version| { ecosystem:, name:, version: } }

          @client.query_batch(queries).each_with_index do |ids, index|
            result[slice[index]] = ids if ids.any?
          end
        end
      end

      # Scarica i record mancanti o scaduti e li scrive; ritorna { osv_id => Advisory } per tutti gli
      # id richiesti che esistono davvero.
      def sync_advisories(osv_ids)
        return {} if osv_ids.empty?

        known = Vulnerabilities::Advisory.where(osv_id: osv_ids).index_by(&:osv_id)

        osv_ids.each_with_object({}) do |osv_id, result|
          advisory = known[osv_id]
          advisory = refresh(osv_id, advisory) if advisory.nil? || advisory.stale?(@now)
          result[osv_id] = advisory if advisory
        end
      end

      def refresh(osv_id, existing)
        record = @client.vulnerability(osv_id)
        # L'advisory è sparito da OSV (ritirato) dopo essere comparso nel batch: teniamo la copia che
        # abbiamo, se c'è. Cancellarla farebbe sparire dei finding senza che nessuno abbia deciso.
        return existing if record.blank?

        attributes = Vulnerabilities::Osv::AdvisoryAttributes.call(record: record, now: @now)
        advisory = existing || Vulnerabilities::Advisory.new(osv_id: osv_id)
        advisory.assign_attributes(attributes)
        advisory.save!
        advisory
      rescue ActiveRecord::RecordNotUnique
        # Due scansioni concorrenti hanno incontrato lo stesso advisory nuovo: la seconda rilegge.
        Vulnerabilities::Advisory.find_by(osv_id: osv_id)
      end
    end
  end
end
