# frozen_string_literal: true

require "openssl"

module Secrets
  module Consolidation
    # L'impronta di un valore segreto (CYRA-777). Serve a una domanda sola: «questo valore esiste già
    # da qualche altra parte nell'organizzazione?». Non si può rispondere leggendo i valori — sono
    # cifrati in modo NON deterministico, quindi due copie identiche hanno ciphertext diversi — e
    # decifrarli tutti per confrontarli significherebbe tirare in chiaro l'intero vault a ogni giro.
    #
    # HMAC-SHA256 e non un digest nudo: un SHA256 si confronta con un dizionario di valori comuni e
    # rivela quali segreti sono `changeme` o `postgres`. Con una chiave che non esce mai dal server,
    # l'impronta è confrontabile solo con altre impronte prodotte dalla stessa chiave — che è tutto
    # ciò che serve per raggruppare, e niente di più.
    #
    # La chiave è DEDICATA e derivata da `secret_key_base` con un salt che nessun altro usa: non
    # aggiunge un segreto da distribuire (ce n'è già uno in ogni ambiente, e senza quello l'app non
    # parte) e resta comunque separata da qualunque altro uso crittografico del prodotto. Il salt
    # porta la versione: cambiarlo invalida di proposito tutte le impronte esistenti, e il backfill
    # notturno le riscrive.
    #
    # La decisione del 2026-09-04 diceva «chiave dedicata nelle credentials»: questo progetto le
    # credentials non le ha (nessun `config/credentials.yml.enc`; i segreti stanno nel vault
    # CloseYourIt e arrivano da ENV). Una chiave nuova nel vault avrebbe aggiunto un segreto da
    # distribuire in tre ambienti, e senza quello le impronte sparirebbero in silenzio — che è
    # esattamente il guasto muto che questa funzione esiste per evitare. La sostanza della decisione
    # — dedicata, e distinta da quelle di cifratura — resta.
    module Fingerprint
      # Sotto questa lunghezza non si impronta. Non è una questione di sicurezza — la chiave regge
      # comunque — ma di rumore: `1`, `true`, `debug`, `local` sono uguali ovunque senza essere lo
      # stesso segreto, e una proposta che chiede di spostare quelli nell'organizzazione seppellisce
      # sotto il rumore le tre proposte che valgono davvero.
      MIN_LENGTH = 8

      # Il salt della derivazione: cambiare la coda di versione rigenera tutte le impronte.
      KEY_SALT = "closeyourit/secrets/value-fingerprint/v1"

      class << self
        # L'impronta del valore, o nil se quel valore non va confrontato con nessuno (assente, vuoto,
        # più corto della soglia). nil non è un errore: è «di questo non si fanno proposte».
        def for(value)
          return nil if value.nil?

          text = value.to_s
          return nil if text.length < MIN_LENGTH

          OpenSSL::HMAC.hexdigest("SHA256", key, text)
        end

        private

        # Memoizzata: la derivazione è una PBKDF2 e la si paga a ogni salvataggio di un segreto e a
        # ogni riga del backfill, dove sarebbe l'intero costo del giro.
        def key
          @key ||= Rails.application.key_generator.generate_key(KEY_SALT, 32)
        end
      end
    end
  end
end
