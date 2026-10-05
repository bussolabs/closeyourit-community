# frozen_string_literal: true

module Ui
  class TableComponentPreview < ViewComponent::Preview
    # Tabella con row-menu: scorre come tutte le altre; il dropdown è position:fixed
    # (ui--row-menu) → non viene clippato dall'overflow.
    def with_row_menu; end

    # Tabella con molte colonne: overflow-x-auto e cartellino «scorri» su mobile.
    def scrollable; end

    # CYRA-924 — a matrix (C59, C67, C70): sticky name column, exceptional states as pills, a highlighted
    # row; below 768px each row becomes a card (C26, C73).
    def matrix; end

    # CYRA-924 — rows that open their detail (C55), a faded row (C79), a selected row (C74), compact
    # density (C53) and a totals footer.
    def rows; end

    # CYRA-924 — groups in one table (C57, C72): the closed group starts collapsed.
    def grouped; end

    # CYRA-924 — the four states inside the table (C51).
    # @param kind select { choices: [empty, no_results, loading, error] }
    def states(kind: "empty")
      render_with_template(locals: { kind: kind.to_sym })
    end
  end
end
