# frozen_string_literal: true

module Ticketing
  # Il contesto che la scrittura assistita dei ticket allega alla richiesta: la fotografia del
  # progetto (le pagine taggate kb-init, sempre) più al massimo DUE pagine di conoscenza scelte
  # per pertinenza rispetto a quello che l'utente ha scritto.
  #
  # PERCHÉ ESISTE (CYRA-632): fino a ieri Ticketing::ComposeTicket mandava al server AI il solo nome del
  # progetto. Il modello scriveva alla cieca — non sapeva cosa fa il prodotto, con che parole se ne
  # parla, quali decisioni erano già state prese — e da lì uscivano i ticket generici di cui si
  # lamentavano gli utenti.
  #
  # PERCHÉ DUE E NON OTTO. Il RAG di Knowledge::AskPages ne manda 8, corpo + parte tecnica, ~20.000
  # caratteri per domanda: lì la risposta È il contesto, e vale pagarlo. Qui il contesto serve solo
  # a orientare la scrittura di un ticket che l'utente ha già in testa: oltre le prime due pagine si
  # paga banda e si diluisce il segnale, perché il modello inizia a pescare requisiti da pagine che
  # parlano d'altro. Due è anche il numero che sta comodo in un pannello e che una persona può
  # verificare a occhio quando la bozza arriva.
  #
  # NON PASSA tech_spec, di proposito: pesa da solo più del corpo (1.500 contro 700) ed è gergo
  # tecnico, mentre a ComposeTicket serve scrivere descrizione e scenari in linguaggio semplice.
  # Dargli in pasto la parte tecnica lo spingerebbe esattamente dove non deve andare.
  #
  # NON FALLISCE MAI. Servizio embedding giù, non configurato, o nessuna pagina sopra la soglia di
  # pertinenza: torna lista vuota e la composizione prosegue col prompt di sempre. È la stessa
  # regola di tutte le funzioni semantiche dell'app — il degrado è silenzioso per costruzione — e
  # qui conta il doppio: la conoscenza è un di più, non una precondizione, e nessuno deve restare
  # senza bozza perché il servizio di embedding non risponde.
  class ComposeContext < ApplicationService
    # Il contratto con la skill `closeyourit-kb-init` (CYRA-680): le pagine "fotografia del
    # progetto" che pubblica portano questo tag, e sono il contesto minimo garantito della
    # composizione — arrivano dal DB, non dalla ricerca semantica, quindi restano anche quando
    # il servizio di embedding è giù o la richiesta non ha niente di pertinente in KB. Rinominarlo da un lato solo
    # spegne la fotografia in silenzio.
    SNAPSHOT_TAG = "kb-init"
    # Quante quattro: il set canonico della skill è overview/moduli/convenzioni/deploy, e il tetto
    # deve contenerlo tutto — un tetto più basso farebbe sparire una pagina in silenzio a ogni
    # aggiornamento delle altre. Resta un tetto, non un obiettivo: protegge il prompt da chi tagga
    # kb-init a mano mezza knowledge base.
    SNAPSHOT_MAX_PAGES = 4
    MAX_PAGES = 2
    # Allineato a Ticketing::AskTickets::CONTEXT_CHARS: un documento di contesto si legge nello
    # stesso modo, che a leggerlo sia il RAG dei ticket o chi scrive la bozza.
    PAGE_BODY_CHARS = 700

    def initialize(project:, query:, client: nil)
      @project = project
      @query = query.to_s.strip
      @client = client
    end

    # → Array<Knowledge::Page>: prima la fotografia (0..SNAPSHOT_MAX_PAGES), poi le pertinenti
    # (0..MAX_PAGES) nell'ordine della ricerca, senza duplicati. Mai un Result: qui non esiste un
    # esito "fallito" da propagare — chi chiama sa solo se ha del contesto o no.
    def call
      return [] if @query.blank?

      snapshots = snapshot_pages
      snapshots + relevant_pages(exclude_ids: snapshots.map(&:id))
    end

    private

    # Le più aggiornate per prime: la fotografia si riscrive per intero a ogni rilancio della
    # skill, quindi updated_at è la freschezza del contenuto, non un dettaglio di ordinamento.
    def snapshot_pages
      ::Knowledge::Page.related_to_project(@project)
                       .tagged_any([ SNAPSHOT_TAG ])
                       .order(updated_at: :desc)
                       .limit(SNAPSHOT_MAX_PAGES)
                       .to_a
    end

    # Il taglio a MAX_PAGES avviene DOPO aver tolto le pagine già in fotografia: la lista della
    # ricerca è tutta sopra soglia (vedi #relevant_ids), quindi il posto liberato da un duplicato
    # va alla pagina pertinente successiva, non perso.
    def relevant_pages(exclude_ids:)
      ids = (relevant_ids - exclude_ids).first(MAX_PAGES)
      return [] if ids.empty?

      pages_by_id = ::Knowledge::Page.where(id: ids).index_by(&:id)
      ids.filter_map { |id| pages_by_id[id] }
    end

    # Knowledge::SemanticSearch torna gli id GIÀ ordinati e GIÀ tagliati: il rerank passa da
    # Embeddings::Rerank, che applica MIN_SCORE — quindi "niente di pertinente" arriva qui come
    # lista vuota, non come i primi due risultati di una lista di scarti. È la ragione per cui il
    # taglio a MAX_PAGES (in #relevant_pages) avviene DOPO il filtro di pertinenza e non prima:
    # prendere i primi due di una ricerca senza soglia vorrebbe dire allegare sempre due pagine,
    # anche quando non c'entrano.
    def relevant_ids
      result = ::Knowledge::SemanticSearch.call(
        scope: ::Knowledge::Page.related_to_project(@project), query: @query, client: @client
      )
      return [] if result.err?

      result.value
    end
  end
end
