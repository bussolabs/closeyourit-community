# frozen_string_literal: true

module Accounts
  # Costanti del dominio account (rules/constants.md): come si dimostra di essere una persona e per
  # quanto quella dimostrazione resta valida — password, sessioni web, secondo fattore, token del
  # terminale e collegamenti esterni.
  module Constants
    # Interface theme a person picks in Preferences (DESIGN.md A32): system follows the OS setting.
    THEMES = %w[light dark system].freeze

    # Validità del token di reset password (rules/authorization.md — token a scadenza breve).
    TTL_PASSWORD_RESET = 15.minutes

    # Policy password: min 8 + maiuscola + minuscola + numero + carattere speciale.
    PASSWORD_FORMAT = /\A(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}\z/

    # Sessioni web (concern Authentication, CYRA-170). Una sessione muore al più tardi dopo
    # SESSION_ABSOLUTE_TTL dal login (scadenza assoluta, ancorata a created_at) e comunque prima se resta
    # inattiva oltre SESSION_IDLE_TIMEOUT (idle, ancorato a last_active_at). Il cookie firmato porta
    # `expires:` = SESSION_ABSOLUTE_TTL (non più `.permanent` ~20 anni): anche se il record DB sopravvive,
    # il browser scarta il cookie alla scadenza assoluta.
    SESSION_ABSOLUTE_TTL = 14.days
    SESSION_IDLE_TIMEOUT = 7.days
    # last_active_at si riscrive al massimo una volta per questa finestra: senza throttle ogni richiesta
    # autenticata farebbe una UPDATE sulla riga di sessione (idle-timeout ≠ una scrittura per pageview).
    SESSION_LAST_ACTIVE_THROTTLE = 5.minutes

    # 2FA TOTP (CYRA-170). Il secondo fattore va completato entro OTP_PENDING_TTL dal superamento della
    # password: oltre, il pending scade e si ricomincia dal login. OTP_DRIFT = tolleranza di deriva
    # dell'orologio (secondi, avanti e indietro) accettata nella verifica del codice: un intervallo TOTP
    # è 30s, ±30s copre un orologio leggermente sfasato senza allargare troppo la finestra. OTP_RECOVERY_CODES
    # = quanti codici di recupero monouso si generano al setup (mostrati una volta sola).
    OTP_PENDING_TTL = 10.minutes
    OTP_DRIFT = 30
    OTP_RECOVERY_CODES = 10
    # Tentativi falliti del secondo fattore ammessi entro UNA challenge pending prima di annullarla e
    # rimandare al login (lockout legato al pending, non all'IP → resiste anche al brute-force distribuito).
    OTP_MAX_ATTEMPTS = 5
    # Emittente mostrato dall'app authenticator (label del provisioning URI / QR).
    OTP_ISSUER = "CloseYourIt"
    # Finestra entro cui si contano i tentativi falliti della riprova del secondo fattore che precede
    # un'impersonation (CYRA-719). I tentativi si contano SULLA SESSIONE: il freno per indirizzo non
    # basta, perché un cookie rubato si usa da mille indirizzi diversi contro un codice di sei cifre.
    # Allineata alla finestra del throttle rack-attack `impersonation/ip`; la soglia è OTP_MAX_ATTEMPTS.
    IMPERSONATION_REAUTH_TTL = 15.minutes

    # Validità del deep-link /start di collegamento Telegram (token firmato mostrato nella pagina
    # preferenze; l'utente lo apre nel bot per collegare il proprio chat_id).
    TTL_TELEGRAM_LINK = 1.hour

    # CYRA-717 — durata di default di un token CLI personale (Accounts::ApiToken). Un token utente
    # autentica COME la persona, con i suoi permessi LIVE: senza scadenza, uno finito in un backup o
    # in un dotfile vale quanto la password, per sempre. 90 giorni è la finestra oltre la quale chi
    # lo usa davvero rifà `login` senza accorgersene, e chi lo ha dimenticato smette di avercelo.
    API_TOKEN_DEFAULT_LIFETIME_DAYS = 90

    # CYRA-717 — soglia di preavviso della scadenza di un token CLI personale. Più stretta di quella
    # delle credenziali di progetto (Projects::Constants::TOKEN_EXPIRY_DUE_SOON_DAYS, 14 giorni): lì
    # avvisa chi amministra, che deve organizzare la sostituzione; qui lo legge la persona al
    # terminale, che rifà `login` in dieci secondi — un avviso due settimane prima diventerebbe
    # rumore da ignorare per due settimane.
    API_TOKEN_EXPIRY_DUE_SOON_DAYS = 7

    # Device-flow CLI (OAuth 2.0 Device Authorization Grant, RFC 8628). Vedi Accounts::Devices::*.
    TTL_DEVICE_GRANT = 15.minutes
    DEVICE_POLL_INTERVAL = 5 # secondi tra i poll della CLI
    # Alfabeto user-code: niente vocali/0/1/O/I → nessuna parola, nessuna ambiguità di lettura.
    DEVICE_USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ23456789".chars.freeze
  end
end
