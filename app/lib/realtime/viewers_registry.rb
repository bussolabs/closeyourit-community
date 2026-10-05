# frozen_string_literal: true

module Realtime
  # Registro TTL dei "viewer" per-risorsa: alimenta il badge "N persone stanno guardando" su
  # ticket/monitor (Task D2). Per ogni stream-risorsa (Realtime::Streams.viewers) tiene una mappa
  # { token => [account_id, scadenza_epoch] }. Il `count` è il numero di ACCOUNT DISTINTI non scaduti:
  # due tab dello stesso account = una sola persona. Il TTL ripulisce i viewer "crashati" (WebSocket
  # caduto senza unsubscribe): l'entry scade da sola, il conteggio si corregge al prune successivo.
  #
  # Store: Rails.cache. In produzione = Solid Cache (DB-backed) → CONDIVISO tra tutti i processi Puma,
  # quindi il conteggio è corretto cross-worker (le subscription WebSocket sono spalmate sui worker).
  # In test il cache_store è :null_store → gli spec iniettano un MemoryStore reale via `.store=`.
  #
  # Concorrenza: il read-modify-write NON è atomico (Solid Cache non offre op atomiche sugli hash).
  # È un indicatore ambientale best-effort: una race transitoria può sfasare il conteggio di ±1 finché
  # il viewer successivo (sub/unsub/heartbeat) non riscrive la mappa. Accettabile per il caso d'uso.
  module ViewersRegistry
    DEFAULT_TTL = 45 # secondi di vita di un viewer senza refresh (heartbeat client ~20s lo rinnova)
    KEY_PREFIX = "realtime:viewers:"

    class << self
      # Store iniettabile (default Rails.cache). Override solo nei test.
      attr_writer :store

      def store
        @store || Rails.cache
      end

      # Registra o rinfresca il viewer `token` (dell'account `account_id`) sullo stream.
      # Ritorna il conteggio aggiornato di account distinti.
      def register(stream, token:, account_id:, ttl: DEFAULT_TTL)
        entries = prune(read(stream))
        entries[token] = [ account_id, Time.current.to_i + ttl ]
        write(stream, entries, ttl)
      end

      # Rimuove il viewer `token`. Ritorna il conteggio aggiornato.
      def unregister(stream, token:)
        entries = prune(read(stream))
        entries.delete(token)
        write(stream, entries, DEFAULT_TTL)
      end

      # Conteggio corrente: account distinti, viewer scaduti esclusi.
      def count(stream)
        distinct(prune(read(stream)))
      end

      private

      def read(stream)
        store.read(key(stream)) || {}
      end

      # Persiste la mappa. Il TTL del record è un po' più lungo della vita del singolo viewer, così la
      # chiave sopravvive mentre i token scadono per epoch; mappa vuota → cancella la chiave.
      # Ritorna il conteggio.
      def write(stream, entries, ttl)
        if entries.empty?
          store.delete(key(stream))
        else
          store.write(key(stream), entries, expires_in: ttl + DEFAULT_TTL)
        end
        distinct(entries)
      end

      def prune(entries)
        now = Time.current.to_i
        entries.reject { |_token, (_account_id, expires_at)| expires_at <= now }
      end

      def distinct(entries)
        entries.values.map(&:first).uniq.size
      end

      def key(stream)
        "#{KEY_PREFIX}#{stream}"
      end
    end
  end
end
