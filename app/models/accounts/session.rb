# frozen_string_literal: true

module Accounts
  # Sessione di autenticazione (pattern Rails 8). Una per login/dispositivo;
  # referenziata dal cookie firmato `session_id`.
  class Session < ApplicationRecord
    self.table_name = "accounts_sessions"

    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :sessions

    # Impostato quando un god sta impersonando un altro account (l'app "vede" questo account).
    belongs_to :impersonated_account,
               class_name: "Accounts::Account",
               optional: true

    # Sessioni ancora valide: non scadute (finestra assoluta) E non idle (attività recente). Speculare a
    # #expired?/#idle?. Esclude le righe con colonne nil (mai per le sessioni reali: start_new_session_for
    # le popola sempre e la migration ha backfillato le pre-esistenti).
    scope :active, lambda {
      where(expires_at: Time.current..)
        .where(last_active_at: Accounts::Constants::SESSION_IDLE_TIMEOUT.ago..)
    }

    def impersonating?
      impersonated_account_id.present?
    end

    # Scaduta oltre la finestra assoluta dal login (CYRA-170). expires_at nil (teorico, mai per le
    # sessioni reali) → non scaduta: nessun logout accidentale su un dato incompleto.
    def expired?
      expires_at.present? && expires_at < Time.current
    end

    # Inattiva oltre SESSION_IDLE_TIMEOUT dall'ultima attività (CYRA-170). last_active_at nil → non idle.
    def idle?
      last_active_at.present? && last_active_at < Accounts::Constants::SESSION_IDLE_TIMEOUT.ago
    end

    # Questa sessione ha superato il secondo fattore (CYRA-170 FIX-5)? Vero se marcata al login 2FA o
    # all'enrollment (che prova comunque il possesso del codice). È il gate — insieme a otp_enabled? —
    # per le capacità god (Valhalla + avvio impersonation): una sessione pre-2FA non entra in Valhalla.
    def two_factor_verified?
      two_factor_verified_at.present?
    end

    # Nome leggibile del dispositivo ("Chrome · macOS"), dal solo User-Agent registrato al login
    # (CYRA-643). Riusa il parser di Analytics::Device: un secondo parser da tenere allineato è un
    # secondo parser che invecchia. nil quando lo User-Agent manca o non è riconoscibile — la pagina
    # scrive allora "Dispositivo sconosciuto", che aiuta più di una riga "Mozilla/5.0 (…)" in cui
    # nessuno riconosce il proprio portatile. È presentazione, non identità: si chiude la sessione che
    # non si riconosce, e questa etichetta serve solo a riconoscerla.
    def device_label
      parsed = Analytics::Device.parse(user_agent)
      [ parsed.browser, parsed.os ].compact.join(" · ").presence
    end
  end
end
