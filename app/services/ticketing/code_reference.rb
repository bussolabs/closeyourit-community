# frozen_string_literal: true

module Ticketing
  # Traduce il CODICE di un ticket ("ALEX-3") nel ticket vero. Il codice non è una colonna: è
  # `project.key + "-" + number` (Ticketing::Ticket#code), quindi non esiste ILIKE che lo trovi —
  # serve spezzarlo e cercare la coppia (project_id, number).
  #
  # Nel repo la stessa regex viveva in sei posti indipendenti, e il commento in
  # Member::AgentsController lo ammetteva. Questo è il posto per chi deve risolvere un ELENCO di
  # codici dentro uno scope già ristretto, in una query sola. Restano fuori i casi con vincoli
  # propri: CLI e webhook GitHub conoscono già il progetto dal path/repo (regex ancorata a quella
  # key), Telegram e Chat cercano cross-org con anti-BOLA proprio, Agents::Leases::Operation
  # normalizza per il wire. Unificare anche quelli è un lavoro a sé, non un effetto collaterale.
  class CodeReference
    # Nessun cap sulla key, di proposito. `Projects::Project` la valida `maximum: 4`, ma è una regola
    # del MODEL: il database non la impone, e non è detto sia sempre esistita — una key legacy più
    # lunga smetterebbe di risolvere, e questo servizio ha ereditato chiamanti (la dashboard agenti)
    # che prima usavano `[A-Za-z0-9]+`. Stringere qui sarebbe una regressione silenziosa.
    #
    # Non costa nulla essere larghi: una stringa che non corrisponde a nessun progetto semplicemente
    # non risolve, e il chiamante prosegue con la ricerca normale. Il numero invece resta limitato —
    # parte da 1 (`assign_number`) e dieci cifre bastano a chiunque.
    PATTERN = /\A([A-Za-z0-9]+)-([1-9]\d{0,9})\z/

    Reference = Data.define(:key, :number)

    # Nil quando il testo non è un codice: il chiamante prosegue con la ricerca normale.
    def self.parse(text)
      match = PATTERN.match(text.to_s.strip)
      return unless match

      Reference.new(key: match[1].upcase, number: match[2].to_i)
    end

    # I ticket dei riferimenti dati, DENTRO lo scope ricevuto. Ritorna una relation (non un hash):
    # chi chiama aggiunge i propri `includes` senza che questo servizio debba indovinarli.
    #
    # `projects` è la relation dei progetti su cui è lecito risolvere le key — è lì che vive
    # l'anti-BOLA, esplicito nel chiamante: un codice di un progetto non visibile semplicemente non
    # risolve, e la ricerca prosegue senza di lui.
    def self.resolve(scope:, projects:, references:)
      references = Array(references).compact
      return scope.none if references.empty?

      by_key = projects.where(key: references.map(&:key).uniq).index_by(&:key)
      pairs = references.filter_map { |reference| [ by_key[reference.key].id, reference.number ] if by_key[reference.key] }
      return scope.none if pairs.empty?

      # Una query per N riferimenti: un find_by per riga sarebbe un N+1 gratuito.
      scope.where(pairs.map { "(ticketing_tickets.project_id = ? AND ticketing_tickets.number = ?)" }.join(" OR "),
                  *pairs.flatten)
    end
  end
end
