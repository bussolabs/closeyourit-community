# frozen_string_literal: true

module Ui
  class SectionComponentPreview < ViewComponent::Preview
    # Il caso normale: titolo e corpo con il padding standard.
    def default; end

    # Con i comandi a destra del titolo (selettore d'intervallo, filtri).
    def with_actions; end

    # Corpo nudo: quello che sta dentro arriva fino al bordo (tabelle, elenchi divisi).
    def flush_body; end

    # La cornice ambra: la sezione che segnala qualcosa da guardare.
    def amber; end
  end
end
