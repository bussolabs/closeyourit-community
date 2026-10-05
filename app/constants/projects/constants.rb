# frozen_string_literal: true

module Projects
  # Costanti del dominio progetti (rules/constants.md): come si guarda la lista, come si giudica la
  # freschezza delle fonti di telemetria e quando una credenziale di ingest sta per non valere più.
  module Constants
    # Modalità di visualizzazione della lista progetti (preferenza utente + default org).
    VIEWS = %w[cards table].freeze

    # Card "Monitoring tools" (fonti di telemetria per progetto). Freschezza di una fonte osservata:
    # entro FRESH è "attiva" (verde), tra FRESH e STALE è "silente da un po'" (ambra), oltre STALE è
    # trattata come "mancante" (rosso), come una fonte attesa mai vista.
    SOURCE_FRESH_WITHIN = 24.hours
    SOURCE_STALE_WITHIN = 7.days
    # Coalesce dell'upsert della fonte (Projects::Source.track!) sotto burst d'ingest (CYRA-42): un solo
    # upsert per [progetto, tool, versione] per finestra, così un backend che emette centinaia di
    # eventi/sec con lo stesso SDK non ricontende la riga hot projects_sources ad ogni campione. La
    # versione è nella chiave di coalesce → un upgrade dell'SDK usa una chiave nuova e passa SUBITO. Un
    # minuto è irrilevante rispetto alle soglie di freschezza sopra (24h/7g), quindi last_seen_at resta
    # sufficientemente fresco pur azzerando la contesa.
    SOURCE_TRACK_COALESCE_INTERVAL = 1.minute

    # CYRA-716 — soglia di preavviso della scadenza di una credenziale di ingest (Projects::Token).
    # Entro N giorni dalla scadenza lo stato passa da :ok a :due_soon e parte il promemoria. Stessa
    # misura della rotazione dei secret (Secrets::Constants::ROTATION_DUE_SOON_DAYS): sono la stessa
    # domanda ("questa credenziale sta per non valere più"), e due finestre diverse per la stessa
    # domanda sarebbero solo da ricordare a memoria.
    TOKEN_EXPIRY_DUE_SOON_DAYS = 14

    # A milestone due within this many days turns amber in the list and in Details.
    MILESTONE_DUE_SOON_DAYS = 7
  end
end
