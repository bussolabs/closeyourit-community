# frozen_string_literal: true

module Agents
  module Leases
    # Titolare di un lease: un host automator (canale /api/v1, token cyi_ah_) oppure un account
    # (canale /cli/v1, token utente cyi_u_ — persona o service account). Le operazioni acquire/renew/
    # release ragionano su questo, non sull'host, così la mutua esclusione vale fra canali diversi.
    Holder = Data.define(:kind, :id, :record) do
      def self.host(record) = new(kind: :host, id: record.id, record:)

      def self.account(record) = new(kind: :account, id: record.id, record:)

      def host? = kind == :host

      def account? = kind == :account

      # Attributi di possesso da scrivere sulla riga lease/tombstone. L'invariante "esattamente un
      # titolare" (check constraint + validazione) vive nei modelli: qui si azzera sempre l'altro lato
      # per non lasciare residui quando una riga scaduta viene riusata da un titolare di tipo diverso.
      def ownership_attributes
        host? ? { host: record, account: nil } : { host: nil, account: record }
      end
    end
  end
end
