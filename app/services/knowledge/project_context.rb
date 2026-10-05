# frozen_string_literal: true

module Knowledge
  # Il "pacchetto di contesto" di UN progetto: l'elenco corto delle sue pagine di conoscenza, una
  # riga di riassunto ciascuna. Risponde a "cosa si sa già di questo progetto?" — la domanda che si
  # fa chi apre una sessione di lavoro, prima ancora di sapere cosa cercare.
  #
  # PERCHÉ ESISTE (CYRA-767). La conoscenza si scriveva e non si rileggeva: chi arriva su un
  # progetto non vede niente di quello che è già stato imparato, a meno che non lo cerchi apposta —
  # e non cerca chi non sa che c'è qualcosa da trovare.
  #
  # PERCHÉ SOLO UNA RIGA. L'elenco è pensato per essere letto SEMPRE, quindi deve stare in poche
  # righe: i corpi interi lo renderebbero impagabile (4.000 caratteri a pagina per DEFAULT_LIMIT
  # pagine) e chi legge non riuscirebbe più a scorrerlo. Le pagine si aprono una per volta, dopo:
  # è lo stesso rapporto fra ricerca e scheda che c'è nel resto del prodotto.
  #
  # ORDINE PER FRESCHEZZA, non per somiglianza: qui non c'è nessuna domanda su cui misurare la
  # pertinenza — l'unica cosa che si sa è di quale progetto si parla, e la rilevanza la porta già
  # il filtro di progetto. Fra pagine tutte inerenti, la più aggiornata è quella che descrive il
  # progetto com'è adesso. Chi HA una domanda ha già la ricerca semantica e il RAG.
  #
  # Non fallisce mai e non chiama nessun servizio esterno: è una query e un taglio.
  class ProjectContext < ApplicationService
    Row = Data.define(:page, :summary)

    # Quante pagine entrano nel pacchetto. Dodici sta in mezzo schermo e si rilegge senza scorrere;
    # è un tetto, non un obiettivo — un progetto con tre pagine ne restituisce tre.
    DEFAULT_LIMIT = 12
    # Tetto DURO: chi chiede di più non lo ottiene. L'elenco deve restare sostenibile anche quando
    # a chiederlo è un'automazione che lo incolla in testa a ogni sessione, e un tetto negoziabile
    # non è un tetto (Definition of Done: la lunghezza non cresce col numero di pagine).
    MAX_LIMIT = 30
    # Una riga di terminale piena. Serve a riconoscere la pagina, non a sostituirla.
    SUMMARY_CHARS = 150

    attr_reader :limit

    # scope = la relation delle pagine VISIBILI al chiamante (già filtrata per stato e permessi dal
    # canale). Il servizio la restringe, non la allarga mai: vedi #pages.
    def initialize(project:, scope:, limit: nil)
      @project = project
      @scope = scope
      @limit = clamp(limit)
    end

    # → Array<Row>, dalla pagina più aggiornata alla più vecchia. Vuoto se il progetto non ha
    # ancora niente: nessun errore e niente di inventato.
    def call
      pages.map { |page| Row.new(page: page, summary: self.class.summarize(page.body)) }
    end

    # Prime SUMMARY_CHARS del corpo su UNA riga, saltando i titoli markdown: sono la struttura del
    # documento, non il suo contenuto, e una riga di riassunto che dicesse "Contesto" non
    # distinguerebbe una pagina dall'altra. nil se non resta niente da leggere.
    def self.summarize(body)
      body.to_s
          .lines
          .reject { |line| line.lstrip.start_with?("#") }
          .join(" ")
          .squish
          .presence
          &.truncate(SUMMARY_CHARS)
    end

    private

    # Restrizione per SOTTOINSIEME e non `merge`: la relation del chiamante resta la base, e le
    # condizioni di Page.related_to_project si aggiungono in AND senza poterne sovrascrivere
    # nessuna. Con `merge`, due `where` sulla stessa colonna (organization_id, status) si
    # sostituiscono invece di sommarsi — basterebbe uno scope costruito male perché il pacchetto
    # mostrasse pagine di un'altra organizzazione.
    def pages
      @scope.where(id: ::Knowledge::Page.related_to_project(@project).select(:id))
            .reorder(nil)
            .ordered
            .limit(@limit)
            .to_a
    end

    # Un tetto chiesto fuori scala (o non numerico) NON è un errore: il pacchetto di contesto è una
    # comodità e deve rispondere comunque, col tetto sensato più vicino.
    def clamp(value)
      requested = value.to_s.strip.to_i
      return DEFAULT_LIMIT if requested <= 0

      [ requested, MAX_LIMIT ].min
    end
  end
end
