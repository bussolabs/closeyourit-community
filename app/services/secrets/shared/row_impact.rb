# frozen_string_literal: true

require "digest"

module Secrets
  module Shared
    # Digest di conferma AGGREGATO per un salvataggio riga-intera che tocca più valori delegati.
    # Riusa Secrets::Shared::Impact (per-cella) e combina i digest in un unico digest deterministico
    # (indipendente dall'ordine delle celle), stabile finché i destinatari (progetti delegati) non
    # cambiano — il digest per-cella dipende da effect+name+progetti, non dal valore. Consumato da
    # Secrets::Shared::Rows::Save per il banner di conferma della riga.
    class RowImpact < ApplicationService
      def initialize(shared_values:, effect: :rotate)
        @shared_values = shared_values
        @effect = effect.to_s
      end

      def call
        entries = @shared_values.map do |shared_value|
          impact = Impact.call(shared_value:, effect: @effect).value
          {
            "name" => shared_value.name,
            "environment" => shared_value.environment.code,
            "projects" => impact["projects"],
            "digest" => impact["digest"]
          }
        end
        digest = Digest::SHA256.hexdigest(entries.map { |entry| entry["digest"] }.sort.join)
        Result.ok("effect" => @effect, "entries" => entries.map { |entry| entry.except("digest") }, "digest" => digest)
      end
    end
  end
end
