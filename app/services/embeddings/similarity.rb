# frozen_string_literal: true

module Embeddings
  # Traduzione fra la scala del motore e la scala che si legge in pagina, in UN posto solo (CYRA-633).
  #
  # Il retrieval vettoriale ragiona in DISTANZA coseno (0 = identici, cresce allontanandosi); chi
  # guarda lo schermo ragiona in SOMIGLIANZA (100% = identici). Sono lo stesso numero letto al
  # contrario, ma la conversione era già scritta a mano in Knowledge::RelatedPages (`1.0 - distance`,
  # tenuta lì in scala 0..1 per il serializzatore) e stava per esserlo una seconda volta nei
  # duplicati dei ticket: due copie della stessa formula sono due posti dove arrotondare in modo
  # diverso e mostrare 84% e 85% per la stessa coppia. Quella di Knowledge non è ancora migrata qui:
  # è il prossimo chiamante naturale, e finché resta fuori questa nota è il promemoria.
  #
  # Gemello di Embeddings::Relevance (le soglie della ricerca): lì stanno i numeri, qui la scala.
  module Similarity
    # Somiglianza 0..1 dalla distanza coseno. Il clamp inferiore serve perché la distanza coseno di
    # pgvector arriva fino a 2 (vettori opposti): senza, si mostrerebbe una percentuale negativa.
    def self.score(distance)
      return nil if distance.nil?

      [ 1.0 - distance.to_f, 0.0 ].max
    end

    # Somiglianza in percento intero. Intero di proposito: il numero è una stima del modello, e i
    # decimali suggerirebbero una precisione che non ha.
    def self.percent(distance)
      score = score(distance)
      return nil if score.nil?

      (score * 100).round
    end
  end
end
