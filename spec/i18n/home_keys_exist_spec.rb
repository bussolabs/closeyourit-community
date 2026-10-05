# frozen_string_literal: true

require "rails_helper"

# CYRA-658 — potando le chiavi del vecchio feed ne è stata portata via una ancora viva
# (`member.home.actions.ticket_concluded`, letta da Agents::Workflows::ConcludedTicketGate). Il
# sintomo non compare da nessuna parte: nessuno spec la esercitava, `raise_on_missing_translations`
# è commentato in test, e il messaggio d'errore che l'utente avrebbe letto era
# «Translation missing: it.member.home.actions.ticket_concluded».
#
# Questa guardia rilegge il codice e pretende che ogni chiave `member.home.*` che qualcuno scrive
# esista davvero, in tutte e due le lingue. Costa una scansione di file; la alternativa è scoprirlo
# da chi usa il prodotto.
RSpec.describe "Chiavi member.home citate nel codice", type: :model do
  LINGUE = %i[it en].freeze

  # Solo le chiavi COMPLETE e letterali: una costruita per interpolazione non si può verificare da
  # qui, e fingere di farlo darebbe una guardia che tace proprio dove serve.
  CHIAVE = /\bt\(\s*["'](member\.home\.[a-z0-9_.]+)["']/
  RADICI = %w[app lib].freeze

  def chiavi_citate
    RADICI.flat_map do |radice|
      Dir[Rails.root.join(radice, "**", "*.{rb,erb}")].flat_map do |file|
        File.read(file).scan(CHIAVE).flatten.map { |chiave| [ chiave, file ] }
      end
    end.uniq
  end

  it "ogni chiave citata esiste in italiano e in inglese" do
    mancanti = chiavi_citate.flat_map do |chiave, file|
      LINGUE.filter_map do |lingua|
        next if I18n.exists?(chiave, lingua)

        "#{chiave} (#{lingua}) — citata da #{Pathname(file).relative_path_from(Rails.root)}"
      end
    end

    expect(mancanti).to be_empty, "chiavi citate dal codice ma assenti dai file di lingua:\n#{mancanti.join("\n")}"
  end
end
