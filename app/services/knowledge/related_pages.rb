# frozen_string_literal: true

module Knowledge
  # Pagine correlate a una o più pagine KB, opzionalmente FILTRATE dalla domanda che ha portato
  # lì. Risponde a "ho estratto questa pagina: cos'altro devo leggere per rispondere?".
  #
  # I candidati arrivano da due direzioni complementari:
  #   • `:link`     — i wikilink, in entrata e in uscita: intenzione esplicita di chi ha scritto;
  #   • `:semantic` — i vicini per significato: la rete di sicurezza per ciò che nessuno ha
  #                   collegato a mano.
  # A parità di pagina vince `:link` (un'intenzione dichiarata batte una somiglianza calcolata).
  #
  # Con una domanda, ogni candidato viene ri-punteggiato sul vettore della domanda (coseno in
  # Ruby: i vettori sono già in memoria, nessuna seconda query) e chi resta oltre MAX_DISTANCE
  # viene scartato — è il "sono inerenti?" che separa questo servizio da una lista di link.
  #
  # SICUREZZA: i candidati sono sempre intersecati con `scope`, la relazione delle pagine
  # VISIBILI al chiamante. Una pagina può citare un progetto che chi legge non vede, e quel
  # collegamento non deve mai trapelare.
  #
  # Ritorna un Array<Row> (mai un Result): non fallisce per definizione — col servizio embedding
  # giù degrada all'ordine "prima i collegamenti", senza punteggio.
  class RelatedPages < ApplicationService
    Row = Data.define(:page, :via, :relevance)
    Candidate = Data.define(:page, :via, :source_distance)

    TOP_K = 5
    # Distanza coseno pgvector ∈ [0,2]: la stessa soglia di Knowledge::SemanticSearch.
    MAX_DISTANCE = 0.6
    # Vicini raccolti per pagina sorgente prima del merge e del taglio finale.
    SEMANTIC_TOP_K = 10
    # Sorgenti espanse semanticamente (una query ciascuna): oltre, il costo non paga la recall.
    MAX_SOURCES = 8

    def initialize(pages:, scope:, question: nil, question_vector: nil,
                   links_only: false, grouped: false, limit: TOP_K, client: nil)
      @sources = Array(pages).compact
      @scope = scope
      @question = question.to_s.strip
      @question_vector = question_vector
      @links_only = links_only
      @grouped = grouped
      @limit = limit
      @client = client
    end

    def call
      return @grouped ? {} : [] if @sources.empty?

      vector = question_vector
      return grouped(vector) if @grouped

      candidates = deduplicate(linked_candidates + semantic_candidates)
      return [] if candidates.empty?

      rank(candidates, vector).first(@limit)
    end

    private

    def source_ids = @source_ids ||= @sources.map(&:id)

    # Modalità lista: `{id sorgente => righe}` dai SOLI collegamenti espliciti. La parte semantica
    # è esclusa di proposito — su una lista costerebbe una query di vicini per riga, e i vicini di
    # un risultato di ricerca semantica sono in larga parte gli altri risultati.
    def grouped(vector)
      candidates_by_source.each_with_object({}) do |(source_id, candidates), result|
        rows = rank(candidates.uniq { |candidate| candidate.page.id }, vector).first(@limit)
        result[source_id] = rows if rows.any?
      end
    end

    # Collegamenti in ENTRAMBE le direzioni: "questa cita X" e "Y cita questa" sono entrambe piste
    # da seguire. Una sola query per TUTTE le sorgenti, orientata come `[sorgente, altro capo]`;
    # un collegamento fra due sorgenti compare una volta per ciascuna delle due.
    def link_pairs
      @link_pairs ||= Connections::PageLink.involving(source_ids)
                                           .pluck(:page_id, :related_id)
                                           .flat_map { |page_id, related_id| orientations(page_id, related_id) }
    end

    def orientations(page_id, related_id)
      pairs = []
      pairs << [ page_id, related_id ] if source_ids.include?(page_id)
      pairs << [ related_id, page_id ] if source_ids.include?(related_id)
      pairs
    end

    def linked_pages_by_id
      @linked_pages_by_id ||= visible(link_pairs.map(&:last).uniq).index_by(&:id)
    end

    def candidates_by_source
      link_pairs.group_by(&:first).transform_values do |pairs|
        pairs.filter_map { |_source_id, other_id| link_candidate(other_id) }
      end
    end

    # In modalità piatta le sorgenti non sono candidate di sé stesse: chi ha chiesto ha già in mano
    # quelle pagine (le citazioni di una risposta, la pagina che sta leggendo).
    def linked_candidates
      link_pairs.reject { |_source_id, other_id| source_ids.include?(other_id) }
                .filter_map { |_source_id, other_id| link_candidate(other_id) }
    end

    def link_candidate(page_id)
      page = linked_pages_by_id[page_id]
      Candidate.new(page: page, via: :link, source_distance: nil) if page
    end

    def semantic_candidates
      return [] if @links_only

      @sources.first(MAX_SOURCES).flat_map do |source|
        vector = source.embedding
        # CYRA-168: salta la sorgente il cui vettore è di versione superata (re-embed in corso):
        # i suoi vicini coseno non hanno senso contro righe di versione corrente. I collegamenti
        # espliciti della sorgente restano — sono intenzione dichiarata, indipendente dall'embedding.
        next [] if vector.blank? || stale?(source)

        neighbours(vector)
      end
    end

    def stale?(page)
      page.embedding_version != Ai::Configuration.current.embedding_version
    end

    def neighbours(vector)
      @scope.reorder(nil)
            .where.not(embedding: nil).current_embedding
            .where.not(id: source_ids)
            .nearest_neighbors(:embedding, vector.to_a, distance: "cosine")
            .limit(SEMANTIC_TOP_K)
            .filter_map do |page|
              next if page.neighbor_distance > MAX_DISTANCE

              Candidate.new(page: page, via: :semantic, source_distance: page.neighbor_distance)
            end
    end

    def visible(ids)
      @scope.reorder(nil).where(id: ids).to_a
    end

    # Stessa pagina raggiunta da più strade (o da più sorgenti): una riga sola, `:link` prevale.
    def deduplicate(candidates)
      candidates.group_by { |candidate| candidate.page.id }.map do |_id, group|
        group.find { |candidate| candidate.via == :link } || group.min_by(&:source_distance)
      end
    end

    def rank(candidates, vector)
      return rank_by_origin(candidates) if vector.nil?

      scored, unscored = candidates.partition { |candidate| current_embedding?(candidate.page) }
      rank_by_question(scored, vector) + trailing_links(unscored)
    end

    # CYRA-168: punteggiabile sulla domanda solo con un embedding della versione CORRENTE — un
    # vettore stale darebbe una distanza coseno falsa contro il vettore-domanda (corrente). Una
    # pagina collegata stale/non indicizzata scivola nei trailing_links, mostrata senza punteggio.
    def current_embedding?(page)
      page.embedding.present? && !stale?(page)
    end

    def rank_by_question(candidates, vector)
      candidates
        .filter_map do |candidate|
          distance = cosine_distance(vector, candidate.page.embedding.to_a)
          next if distance.nil? || distance > MAX_DISTANCE

          [ distance, candidate ]
        end
        .sort_by { |distance, candidate| [ distance, candidate.page.title ] }
        .map { |distance, candidate| Row.new(page: candidate.page, via: candidate.via, relevance: (1.0 - distance).round(3)) }
    end

    # Un collegamento verso una pagina non ancora indicizzata non è valutabile: lo teniamo in
    # coda senza punteggio invece di nasconderlo — l'autore l'ha scritto apposta.
    def trailing_links(candidates)
      candidates.select { |candidate| candidate.via == :link }
                .sort_by { |candidate| candidate.page.title }
                .map { |candidate| Row.new(page: candidate.page, via: :link, relevance: nil) }
    end

    # Senza domanda (o col servizio embedding giù) non c'è pertinenza da misurare: prima
    # l'intenzione esplicita, poi la somiglianza con la pagina di partenza.
    def rank_by_origin(candidates)
      links, semantic = candidates.partition { |candidate| candidate.via == :link }
      ordered = links.sort_by { |candidate| candidate.page.title } +
                semantic.sort_by { |candidate| [ candidate.source_distance, candidate.page.title ] }
      ordered.map { |candidate| Row.new(page: candidate.page, via: candidate.via, relevance: nil) }
    end

    # Degrado silenzioso: servizio giù → nil → si ricade sull'ordine per provenienza.
    def question_vector
      return @question_vector.to_a if @question_vector.present?
      return nil if @question.blank?

      result = Embeddings::QueryVector.call(query: @question, client: @client)
      result.ok? ? result.value : nil
    end

    # Identica alla distanza coseno di pgvector (1 - similarità), calcolata qui perché entrambi i
    # vettori sono già caricati: interrogare di nuovo il DB per confrontarli sarebbe uno spreco.
    def cosine_distance(left, right)
      dot = norm_left = norm_right = 0.0
      left.each_with_index do |value, index|
        other = right[index].to_f
        dot += value * other
        norm_left += value * value
        norm_right += other * other
      end
      return nil if norm_left.zero? || norm_right.zero?

      1.0 - (dot / (Math.sqrt(norm_left) * Math.sqrt(norm_right)))
    end
  end
end
