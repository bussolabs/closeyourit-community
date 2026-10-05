# frozen_string_literal: true

module Home
  # «Non oggi»: una card della coda che questo account non vuole vedere fino a domani mattina.
  # È un gesto PERSONALE e non tocca il record deciso — chi ha chiesto quella cosa continua a
  # vederla in attesa, perché per lui non è cambiato niente.
  #
  # `card_key` è la chiave "famiglia:uuid" con cui Home::Feed::Item nomina una card, non una FK: le
  # quattro famiglie della coda vivono in quattro tabelle diverse. Il prezzo è che una card
  # cancellata lascia qui una riga orfana: la pota il job di retention, e intanto non fa danno
  # perché una key che non risolve semplicemente non compare in coda.
  #
  # Da NON confondere con `waiting` (Home::Approvals::Queue#with_waiting): quello è «ho chiesto una
  # precisazione, la palla è di qualcun altro» e resta in coda in fondo; questo è «la palla è mia,
  # ma non oggi» ed esce dalla coda del tutto.
  class Deferral < ApplicationRecord
    belongs_to :account, class_name: "Accounts::Account", inverse_of: :home_deferrals
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :home_deferrals

    attr_readonly :organization_id

    normalizes :card_key, with: ->(value) { value.to_s.strip }

    validates :card_key, presence: true
    validates :until_at, presence: true

    # I rimandi ancora validi: quelli scaduti sono già tornati in coda e non nascondono più niente.
    scope :live, -> { where(until_at: Time.current..) }
    scope :expired, -> { where(until_at: ...Time.current) }

    # Le chiavi da scartare quando si sceglie la prossima decisione. Un Set perché chi chiama ci fa
    # un lookup per ogni riga della coda.
    #
    # Scoped all'ORGANIZZAZIONE e non al solo account: la coda che si sta guardando è di
    # un'organizzazione sola, e i rimandi fatti altrove non c'entrano niente con lei. Senza questo
    # filtro il numero «N rimandate a domani» conterebbe anche i rimandi di un'altra organizzazione,
    # e si leggerebbe «3 rimandate» sopra una coda che non ne ha nessuna.
    def self.live_keys_for(account, organization:)
      live.where(account_id: account.id, organization_id: organization.id).pluck(:card_key).to_set
    end
  end
end
