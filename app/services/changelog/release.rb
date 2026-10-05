# frozen_string_literal: true

module Changelog
  # Una release del CHANGELOG: versione semver, data (stringa come nel file) e sezioni
  # (`Added`/`Changed`/`Fixed`/…) ognuna con le sue voci già normalizzate.
  Release = Data.define(:version, :date, :sections) do
    # Etichetta pronta per la UI (es. "v0.0.52").
    def label = "v#{version}"
  end
end
