# frozen_string_literal: true

module Ticketing
  module Search
    # CYRA-739 — la ricerca dei ticket, in un posto solo. Tre rami che si escludono a vicenda e una
    # rete: codice esatto, per significato, parole esatte. Stava dentro il controller della pagina
    # insieme a bacheca, doppioni e opzioni del modulo, ed era la parte con più regole di tutte.
    #
    # Ritorna sempre un Result: lo scope da mostrare e se la ricerca per significato è DEGRADATA
    # (servizio embedding giù → si ripiega sulle parole esatte). Il degrado non è mai un errore
    # utente: è un avviso muto sopra i risultati.
    class Query < ApplicationService
      Result = Data.define(:scope, :degraded)

      # `projects` serve al solo ramo del codice esatto (Ticketing::CodeReference risolve la sigla
      # sul perimetro visibile). `semantic` è la SCELTA di chi guarda, non un default nascosto qui:
      # la offre la sola vista lista, dove vive il selettore di modalità.
      def initialize(scope:, query:, projects:, semantic: false)
        @scope = scope
        @query = query.to_s.strip
        @projects = projects
        @semantic = semantic
      end

      def call
        return Result.new(scope: @scope, degraded: false) if @query.blank?

        # Un codice ("ALEX-3") è una richiesta ESATTA, non una domanda di somiglianza: chi lo digita
        # sa già cosa vuole, e l'embedding non ha niente da aggiungere. Sta prima del branch
        # semantico perché la modalità predefinita è quella per significato — più in basso non
        # verrebbe mai raggiunto.
        by_code = code_search
        return Result.new(scope: by_code, degraded: false) if by_code

        return Result.new(scope: like_search(@scope), degraded: false) unless @semantic

        semantic_search
      end

      private

      def semantic_search
        result = Ticketing::SemanticSearch.call(scope: @scope, query: @query)
        return Result.new(scope: like_search(@scope), degraded: true) if result.err?

        # Ibrido (pattern di Idee e Conoscenza): prima i ticket per pertinenza semantica, POI i match
        # testuali non già inclusi. La semantica scarta i ticket senza embedding (calcolato da un job
        # asincrono) e taglia anche i candidati non pertinenti: senza questa unione un ticket appena
        # aperto sparirebbe anche cercandone una parola del titolo.
        ordered_ids = result.value + (text_match_ids - result.value)
        return Result.new(scope: @scope.none, degraded: false) if ordered_ids.empty?

        # reorder(nil): l'ordine è la pertinenza (in_order_of filtra E ordina sugli ids passati).
        Result.new(scope: @scope.reorder(nil).in_order_of(:id, ordered_ids), degraded: false)
      end

      # Ids dei ticket il cui testo scritto corrisponde alla query: rete di sicurezza della ricerca
      # semantica. Senza gli includes: servono SOLO gli id, e un ticket con N allegati tornerebbe N
      # volte se il preload diventasse un JOIN (stessa ragione di code_search).
      def text_match_ids
        like_search(@scope).except(:includes, :eager_load, :preload).reorder(nil).pluck(:id)
      end

      # Ricerca testuale (ramo ILIKE): l'indice copre titolo, descrizione, analisi tecnica e scenari
      # (CYRA-387). La query è spezzata in TERMINI con AND fra loro — "deploy bloccato" trova i ticket
      # che nominano entrambe le parole anche non contigue, non solo chi ha la stringa esatta. Ogni
      # termine è un OR sui campi (title/description/technical_analysis del ticket + i 5 campi testuali
      # degli scenari, via EXISTS per non duplicare righe). Il match esatto per codice resta prioritario:
      # code_search intercetta un codice PRIMA di questo ramo, quindi allargare l'indice non lo tocca.
      # I `%`/`_` digitati sono neutralizzati (sanitize_sql_like): "50%" cerca il letterale, non un jolly.
      def like_search(scope)
        @query.split.reduce(scope) do |relation, term|
          like = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
          relation.where(
            "ticketing_tickets.title ILIKE :like OR ticketing_tickets.description ILIKE :like " \
            "OR ticketing_tickets.technical_analysis ILIKE :like OR EXISTS (" \
            "SELECT 1 FROM ticketing_scenarios sc WHERE sc.ticket_id = ticketing_tickets.id AND (" \
            "sc.title ILIKE :like OR sc.step_given ILIKE :like OR sc.step_when ILIKE :like " \
            "OR sc.step_then ILIKE :like OR sc.step_expected ILIKE :like))",
            like: like
          )
        end
      end

      # nil quando `q` non è un codice o non risolve: il chiamante prosegue con la ricerca normale —
      # un codice inventato non deve svuotare la lista, deve solo non trovare quel ticket.
      def code_search
        reference = Ticketing::CodeReference.parse(@query)
        return unless reference

        exact = Ticketing::CodeReference.resolve(scope: @scope, projects: @projects,
                                                 references: [ reference ]).first
        return unless exact

        @scope.reorder(nil).in_order_of(:id, [ exact.id ] + citing_ids(reference, exact))
      end

      # Chi lo cita: spesso è ciò che si cerca davvero ("dove ne abbiamo parlato?"). Cap allineato a
      # SemanticSearch::TOP_K — senza, un codice molto citato genererebbe un ORDER BY CASE enorme.
      #
      # Confine di parola (`\y`) invece di un LIKE con i jolly: il numero è un PREFISSO di altri
      # numeri, quindi `%CYRA-14%` pescherebbe anche CYRA-141 e CYRA-142. Il codice usato è quello
      # canonico del riferimento, non `q` grezzo, così maiuscole e spazi non cambiano il risultato;
      # key e numero sono `[A-Za-z0-9]` per costruzione, quindi non c'è nulla da escapare.
      #
      # Qui servono SOLO gli id: gli `includes` dello scope (allegati compresi) diventerebbero JOIN e
      # un ticket con N allegati tornerebbe N volte, mangiandosi N posti del cap ed escludendo
      # citanti validi. Verificato: 2 allegati → 2 righe per lo stesso ticket.
      #
      # `reorder` esplicito PRIMA del cap: un LIMIT senza ordinamento proprio taglia in modo
      # arbitrario — quali citanti entrano dipenderebbe dall'ordinamento colonna scelto dall'utente,
      # e a parità di data l'ordine fra i pari è indefinito. `id` chiude il pareggio.
      # Anche l'analisi tecnica: è LÌ che si citano i codici. Misurato in produzione — 160 ticket
      # nominano un codice SOLO nell'analisi, contro 104 fra titolo e descrizione. Guardare le sole
      # due colonne ovvie avrebbe perso il caso più frequente, e questo ramo interrompe la ricerca
      # semantica, quindi quei ticket non sarebbero emersi in nessun altro modo.
      #
      # Restano fuori scenari e condizioni (14 casi): vivono in tabelle separate e nemmeno
      # l'embedding li considera, per non diluire la semantica del problema. Limite dichiarato.
      def citing_ids(reference, exact)
        code = "#{reference.key}-#{reference.number}"
        @scope.except(:includes, :eager_load, :preload)
              .where("ticketing_tickets.title ~* :re OR ticketing_tickets.description ~* :re " \
                     "OR ticketing_tickets.technical_analysis ~* :re",
                     re: "\\y#{code}\\y")
              .where.not(id: exact.id)
              .reorder(created_at: :desc, id: :desc)
              .limit(Embeddings::Relevance::TOP_K).pluck(:id)
      end
    end
  end
end
