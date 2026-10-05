# frozen_string_literal: true

module Ui
  class DescriptionListComponentPreview < ViewComponent::Preview
    # Il riquadro «Dettagli» come lo scrivono le pagine: due colonne, qualche voce a tutta larghezza.
    def default; end

    # Una voce sola per riga, con l'aiuto accanto all'etichetta.
    def single_column; end
  end
end
