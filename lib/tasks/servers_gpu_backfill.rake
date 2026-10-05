# frozen_string_literal: true

namespace :servers do
  desc "CYRA-703 — riempie uso e watt della scheda grafica sui campioni già salvati"
  task backfill_gpu: :environment do
    updated_count = Servers::GpuBackfill.call
    puts "Campioni aggiornati: #{updated_count}"
  end
end
