# frozen_string_literal: true

module Ticketing
  # Broadcast realtime post-commit dopo l'aggiunta/rimozione di una dipendenza (CYRA-82). Il badge
  # "bloccato" sulla board del ticket DIPENDENTE cambia: un prerequisito aperto in più lo alza, la
  # rimozione dell'ultimo prerequisito aperto lo toglie. Senza questo refresh la board resta stantìa
  # per gli ALTRI viewer fino a un reload manuale (chi muta torna alla show, ma la board è condivisa).
  # Page-refresh throttlato per-progetto, come Ticketing::StatusBroadcasts — il badge è ricalcolato
  # server-side dal ri-fetch, quindi basta il segnale. Il refresh è incondizionato (anche aggiungere un
  # prerequisito GIÀ done non cambia il badge): un page-refresh non trasporta stato ed è idempotente,
  # non vale una seconda query per deciderlo.
  #
  # Va chiamato SOLO dopo il commit della transazione del service (post-commit by construction, come
  # StatusBroadcasts): AddDependency/RemoveDependency lo invocano FUORI dal loro `transaction do…end`,
  # quindi la mutazione è già committata e non serve un callback after_commit.
  module DependencyBroadcasts
    private

    def broadcast_dependency_board(ticket)
      Realtime::ThrottledRefresh.call(Realtime::Streams.project_board(ticket.project))
    end
  end
end
