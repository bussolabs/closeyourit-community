# frozen_string_literal: true

module Servers
  # CYRA-703 — riempie gpu_pct/gpu_watt sui campioni già salvati, che hanno il dettaglio della
  # scheda grafica nel payload ma le colonne vuote (prima di CYRA-703 l'uso a 0% non arrivava
  # affatto). Senza questo giro il grafico nasce con la storia amputata.
  #
  # A blocchi e non in un UPDATE unico: la tabella ha un campione al minuto per host, sono centinaia
  # di migliaia di righe, e un solo statement terrebbe un lock lungo su una tabella che l'ingest
  # sta scrivendo di continuo.
  class GpuBackfill
    DEFAULT_BATCH_SIZE = 5_000

    def self.call(batch_size: DEFAULT_BATCH_SIZE) = new(batch_size: batch_size).call

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      updated_count = 0
      scope.in_batches(of: @batch_size) do |batch|
        batch.each do |sample|
          values = gpu_values(sample.payload)
          next if values.blank?

          sample.update_columns(**values)
          updated_count += 1
        end
      end
      updated_count
    end

    private

    # Solo i campioni ancora scoperti: rilanciare il giro non deve riscrivere ciò che è già a posto.
    def scope = Sample.where(gpu_pct: nil).where.not(payload: {})

    def gpu_values(payload)
      gpus = payload.is_a?(Hash) ? payload["gpu"] : nil
      return nil unless gpus.is_a?(Hash)

      items = gpus.values.select { |gpu| gpu.is_a?(Hash) }
      usi = items.filter_map { |gpu| gpu["u"]&.to_f }
      return nil if usi.empty?

      watt = items.filter_map { |gpu| gpu["p"]&.to_f }
      { gpu_pct: usi.max.round(2), gpu_watt: (watt.sum.round(2) if watt.any?) }.compact
    end
  end
end
