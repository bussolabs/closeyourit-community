# frozen_string_literal: true

require "rails_helper"

# CYRA-840 — in Valhalla due interruttori AI si chiamavano «Label» e «Hint»: le chiavi
# `valhalla.settings.ai.services.<key>.{label,hint}` esistevano per otto servizi su dieci. La view
# le costruisce per interpolazione da Ai::Feature::KEYS, quindi nessuno spec le cita letteralmente e
# la guardia sulle chiavi citate nel codice non le vede. Questa guardia parte dal catalogo: ogni
# servizio nuovo deve arrivare con nome e spiegazione in tutte e due le lingue.
RSpec.describe "Nomi e spiegazioni degli interruttori AI in Valhalla", type: :model do
  LINGUE_INTERRUTTORI = %i[it en].freeze

  it "ogni servizio di Ai::Feature::KEYS ha label e hint in italiano e in inglese" do
    mancanti = Ai::Feature::KEYS.flat_map do |key|
      LINGUE_INTERRUTTORI.flat_map do |lingua|
        %w[label hint].filter_map do |campo|
          chiave = "valhalla.settings.ai.services.#{key}.#{campo}"
          next if I18n.exists?(chiave, lingua)

          "#{chiave} (#{lingua})"
        end
      end
    end

    expect(mancanti).to be_empty, "servizi AI senza nome o spiegazione:\n#{mancanti.join("\n")}"
  end
end
