# frozen_string_literal: true

module Knowledge
  # CYRA-768 — quando una pagina va riletta, dato il suo tipo. Un posto solo, perché la data la
  # scrivono in quattro momenti diversi (accettazione, creazione già pubblicata, riscrittura del
  # testo, conferma) e quattro conti sparsi darebbero scadenze diverse alla stessa pagina a seconda
  # di come ci si è arrivati.
  #
  # Puro come Knowledge::SubstantiveEdit (niente Result, niente DB): riceve un tipo, ritorna una data
  # o nil. nil NON è un errore — è la risposta giusta per una nota, che non invecchia (Scenario 3 del
  # ticket: un appunto non deve intasare la coda) e per qualunque tipo che le finestre non nominano.
  class ReviewSchedule
    def self.next_for(kind:, from: Time.current)
      window = Knowledge::Constants::REVIEW_WINDOWS[kind.to_s]
      window && from + window
    end

    # I tipi che scadono davvero: li usa il backfill per non guardare nemmeno le note.
    def self.expiring_kinds = Knowledge::Constants::REVIEW_WINDOWS.keys
  end
end
