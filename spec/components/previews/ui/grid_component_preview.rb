# frozen_string_literal: true

module Ui
  class GridComponentPreview < ViewComponent::Preview
    # Il corpo di una pagina di dettaglio: una colonna su schermo stretto, tre su schermo largo.
    def responsive; end

    # Le colonne fisse dei riquadri di dettaglio, con distanze diverse fra righe e colonne.
    def fixed; end
  end
end
