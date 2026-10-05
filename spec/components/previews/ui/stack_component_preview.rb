# frozen_string_literal: true

module Ui
  class StackComponentPreview < ViewComponent::Preview
    # La pila verticale: il ritmo con cui si susseguono i riquadri di una pagina.
    def vertical; end

    # La riga: comandi affiancati, allineati al centro.
    def row; end

    # La riga che manda a capo quando lo spazio finisce.
    def row_wrap; end
  end
end
