# frozen_string_literal: true

module Notifications
  # Quello che un dominio deve dire per far partire una notifica: a chi va (account, organization),
  # di cosa parla (subject, project, event_type), cosa legge la persona (title, body, url, details) e
  # con quale chiave si riconosce il doppione (dedup_key). Nient'altro: la consegna vera —
  # scrivere la riga, deduplicarla, spedirla, segnarne lo stato — è di Notifications::Deliver.
  #
  # I due campi che restano di dominio perché non c'è un default sensato (CYRA-744):
  # - mailer: il callable che prepara l'email (es. `Ticketing::TicketNotificationsMailer.method(:notify)`).
  #   Serve solo al canale email; ogni dominio ha la sua pagina e il suo nome di metodo.
  # - duplicate_error: cosa torna dentro Result.err quando la dedup_key c'è già. Il simbolo :duplicate
  #   per chi lo tratta come esito atteso, un AppError per chi lo espone a un chiamante HTTP (chat).
  Payload = Data.define(
    :organization, :account, :subject, :event_type, :title, :body, :url, :dedup_key,
    :project, :rule, :details, :mailer, :duplicate_error
  ) do
    # rule nil = notifica di dispatch diretto (ticket, chat, vault, credenziali): non nasce da una
    # regola di monitoraggio configurabile. details nil = nessun elenco esteso dietro "mostra dettagli".
    def initialize(project: nil, rule: nil, details: nil, mailer: nil, duplicate_error: :duplicate, **rest)
      super(project: project, rule: rule, details: details, mailer: mailer,
            duplicate_error: duplicate_error, **rest)
    end
  end
end
