# frozen_string_literal: true

module Secrets
  module Consolidation
    # Scrive l'impronta sui segreti che ne sono privi (CYRA-777): quelli esistenti prima che la
    # colonna nascesse, e quelli entrati mentre una versione senza il callback girava in produzione.
    #
    # GIORNALIERO e non one-shot, per la stessa ragione dei backfill degli embedding (CYRA-232/559):
    # un giro one-shot lanciato a mano al rilascio è il passo che nessuno esegue, e ciò che è entrato
    # nel frattempo resta fuori dai raggruppamenti per sempre — cioè non viene mai proposto.
    #
    # `update_columns` e non `save`: sono righe storiche che potrebbero non passare validazioni nate
    # dopo di loro (un ambiente non più dichiarato dal progetto), e il backfill si fermerebbe lì.
    # L'impronta non è un dato di dominio da validare, è una derivata del valore.
    #
    # I valori troppo corti restano senza impronta per sempre, quindi ogni giro li riguarda: è il
    # prezzo accettato per non avere una seconda colonna che dice «già guardato». Sono decine di
    # righe, non migliaia — le variabili corte sono interruttori, non segreti.
    #
    # Lancio immediato: bin/rails runner 'Secrets::Consolidation::BackfillFingerprintsJob.perform_later'
    class BackfillFingerprintsJob < ApplicationJob
      queue_as :batch

      def perform
        backfill(::Secrets::Variable.where(value_fingerprint: nil))
        backfill(::Secrets::Shared::Value.where(value_fingerprint: nil))
      end

      private

      def backfill(scope)
        scope.find_each do |record|
          fingerprint = Fingerprint.for(record.value)
          next if fingerprint.nil?

          record.update_columns(value_fingerprint: fingerprint)
        end
      end
    end
  end
end
