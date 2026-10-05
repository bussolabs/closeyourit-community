# frozen_string_literal: true

module Member
  module Knowledge
    # Pagina d'ingresso dell'area Conoscenza (CYRA-415): un indice che INSEGNA invece di tre voci
    # parallele senza spiegazione. Per ciascun passo del flusso — Revisione, Conoscenza, Book,
    # nell'ordine d'uso reale (deciso col cliente) — la view mostra una definizione di una riga, un
    # contatore vivo e l'azione tipica.
    #
    # Sola lettura, nessun gate oltre l'auth: i contatori riusano gli scope visibili all'account
    # (VisibleResources), quindi ognuno vede solo i numeri del proprio perimetro. Model SEMPRE
    # fully-qualified ::Knowledge::* come gli altri controller dell'area.
    class OverviewController < Member::BaseController
      permission_not_required "Solo conteggi degli scope già visibili: nessun dato in più rispetto alle pagine che " \
                              "questa indicizza."

      def show
        # Contatori vivi = count aggregati su relation GIÀ scoped: nessuna riga materializzata, una
        # query leggera per numero. È la via che il ticket chiede ("conteggi aggregati") contro il
        # rischio di caricare N pagine per card.
        @review_waiting_count = visible.pages_in_review.count
        @review_to_file_count = visible.pages.awaiting_consolidation.count
        @pages_count = visible.pages.count
        @decisions_count = visible.pages.kind_decision.count
        @books_count = visible.books.count
        # CYRA-930 — under the counts, a row per project like every area landing.
        @matrix = ::Member::KnowledgeMatrix.new(visible_projects: visible.projects, visible_pages: visible.pages,
                                                visible_review: visible.pages_in_review)
        @matrix_pagination = paginate(@matrix.projects_scope)
      end
    end
  end
end
