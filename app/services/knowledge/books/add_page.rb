# frozen_string_literal: true

module Knowledge
  module Books
    # Aggiunge UNA pagina al TOC di un book in una posizione (0-based; nil/blank = in fondo) e
    # restituisce il book col sommario aggiornato. Pensato per le automazioni (canale CLI): granulare
    # dove Books::Save riconcilia l'intero elenco.
    #
    # Guardie:
    # - la pagina deve appartenere a un progetto EFFETTIVO del book (diretto o via gruppo), altrimenti
    #   R422-KNOWLEDGE-006 (stessa regola anti-cross-project di Books::Save#reconcile_pages);
    # - la pagina non può essere già in un ALTRO book (R422-KNOWLEDGE-007): una pagina sta al più in un
    #   book (vincolo del dominio) e strapparla altrove muterebbe un book su cui non si ha titolo.
    #
    # Idempotente: ripetere la stessa chiamata lascia il TOC invariato (la pagina già presente viene
    # ricollocata alla stessa posizione, mai duplicata). Riscrive book_id + position 0..n-1 in un solo
    # UPDATE via update_all (mutazione diretta di FK/position, nessun callback — come Books::Save).
    # Tutto sotto lock del book: add-page concorrenti sullo stesso book si serializzano (niente
    # position duplicate) e l'aggiunta tocca updated_at (il book risale nell'ordinamento per modifica).
    class AddPage < ApplicationService
      def initialize(book:, page:, position: nil)
        @book = book
        @page = page
        @position = position
      end

      def call
        # @page.project_id e' solo uno shim post-CYRA-174 (primo progetto, o nil per le pagine
        # org-wide): con una pagina multi-progetto controllava un progetto a caso, con una org-wide
        # confrontava nil. La regola vera e' l'INTERSEZIONE fra i progetti effettivi dei due.
        unless @book.effective_projects.exists?(id: @page.effective_projects.select(:id))
          return Result.err(AppError.new(I18n.t("member.knowledge.errors.page_not_in_book"),
                                         code: "R422-KNOWLEDGE-006"))
        end
        if @page.book_id.present? && @page.book_id != @book.id
          return Result.err(AppError.new(I18n.t("member.knowledge.errors.page_in_another_book"),
                                         code: "R422-KNOWLEDGE-007"))
        end

        ActiveRecord::Base.transaction do
          @book.lock!
          reorder!
          @book.touch
        end
        Result.ok(@book)
      end

      private

      # TOC finale = pagine attuali del book (esclusa la target, nel loro ordine) con la target
      # inserita all'indice richiesto (clampato). Poi position ricompattate 0..n-1.
      def reorder!
        current = @book.pages.where.not(id: @page.id).pluck(:id).map(&:to_s)
        ordered = current.insert(insertion_index(current.size), @page.id.to_s)
        apply_positions(ordered)
      end

      def insertion_index(size)
        return size if @position.blank?

        @position.to_i.clamp(0, size)
      end

      def apply_positions(ordered_ids)
        clauses = ([ "WHEN ? THEN ?" ] * ordered_ids.length).join(" ")
        bindings = ordered_ids.each_with_index.flat_map { |id, index| [ id, index ] }
        update_sql = ActiveRecord::Base.sanitize_sql_array(
          [ "book_id = ?, position = CASE id #{clauses} END", @book.id, *bindings ]
        )
        ::Knowledge::Page.where(id: ordered_ids).update_all(update_sql)
      end
    end
  end
end
