# frozen_string_literal: true

require "rails_helper"

# CYRA-574 — in tre punti del prodotto arrivava a schermo il nome interno di una traduzione al posto
# del testo: una casella del progetto si presentava come «Quick Bug Report Enabled Hint», e una
# colonna dei siti diceva «Open Issues» dove tutto il prodotto dice Rilievi.
#
# Il difetto non si vede scrivendo la vista né confrontando le due lingue (locale_parity_spec): la
# chiave manca in ENTRAMBE, quindi le lingue restano pari e i18n stampa il segnaposto a chi legge.
# L'unico controllo che lo trova è questo: chiedere a ogni vista se le traduzioni che nomina
# esistono davvero.
RSpec.describe "Nessuna chiave di traduzione arriva a schermo", type: :model do
  # Le chiamate con una chiave scritta per intero. Restano fuori:
  # - `t(".relativa")`, che i18n risolve dal percorso della vista;
  # - le chiavi composte a runtime (`t("...#{area}")`), che nessuna lettura statica può risolvere —
  #   quelle le presidia il catalogo di chi le genera (es. authorization/catalog_metadata_spec);
  # - le righe con `default:`, dove il testo di ripiego è una scelta, non un buco.
  CHIAVE_SCRITTA_PER_INTERO = /\bt\(\s*["']([a-z][a-z0-9_.]*)["']\s*[,)]/

  def chiavi_nominate_dalle_viste
    Dir[Rails.root.join("app/{views,components}/**/*.erb")].flat_map do |file|
      File.readlines(file).each_with_index.flat_map do |riga, indice|
        next [] if riga.include?("default:")

        riga.scan(CHIAVE_SCRITTA_PER_INTERO).flatten.map { |chiave| [ chiave, "#{relative(file)}:#{indice + 1}" ] }
      end
    end
  end

  def relative(file) = Pathname(file).relative_path_from(Rails.root)

  before { I18n.eager_load! }

  it "ogni traduzione nominata da una vista esiste" do
    mancanti = chiavi_nominate_dalle_viste.reject do |chiave, _dove|
      I18n.exists?(chiave, :it) || I18n.exists?(chiave, :en)
    end

    expect(mancanti).to be_empty, "traduzioni inesistenti: #{mancanti.map { |c, d| "#{d} → #{c}" }.join(', ')}"
  end
end
