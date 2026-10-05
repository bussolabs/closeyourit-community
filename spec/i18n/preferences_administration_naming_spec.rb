# frozen_string_literal: true

require "rails_helper"

# CYRA-338 — «IMPOSTAZIONI» INDICAVA DUE POSTI DIVERSI.
#
# La pagina delle preferenze personali — la lingua, come si vedono gli elenchi, le piattaforme su cui
# lavoro — si intitolava «Impostazioni». Con lo stesso nome, nel menu, si chiamava l'area che governa
# l'organizzazione: membri, team, ruoli, ambienti, piattaforme. Chi cercava «impostazioni» per
# cambiare la propria lingua poteva finire in un'area che ha effetti su tutto il team. E alle
# preferenze si arrivava per giunta da una voce chiamata «Account», che non nomina nulla di ciò che
# quella pagina contiene (in inglese era rimasta senza traduzione).
#
# LA DECISIONE
#   1. L'area personale si chiama «Preferenze» — nel titolo, nella briciola di pane e nella voce di
#      menu da cui si apre.
#   2. L'area dell'organizzazione si chiama «Amministrazione», che è ciò che vi si fa.
#   3. Nessuna delle due si chiama più «Impostazioni».
#
# Il guard non si limita ai due nomi: pretende anche che le tre pagine dell'area personale
# (preferenze, notifiche, Telegram) prendano il titolo dalla STESSA chiave, altrimenti il nome
# tornerebbe a divergere una pagina alla volta.
RSpec.describe "Preferenze e Amministrazione (CYRA-338)", type: :model do
  CYRA338_LINGUE = %i[it en].freeze

  # I due nomi decisi, nelle due lingue. Sono l'elenco a cui riferirsi: si cambiano qui e nel
  # glossario, non in una pagina alla volta.
  CYRA338_PREFERENZE = { it: "Preferenze", en: "Preferences" }.freeze
  CYRA338_AMMINISTRAZIONE = { it: "Amministrazione", en: "Administration" }.freeze

  # Il nome che indicava tutt'e due le cose, nelle due lingue: da qui rientrerebbe la confusione.
  CYRA338_NOME_AMBIGUO = { it: "Impostazioni", en: "Settings" }.freeze

  # Le tre pagine dell'area personale: si aprono dalle schede in cima e devono presentarsi con lo
  # stesso nome, perché sono la stessa area.
  CYRA338_PAGINE_PERSONALI = %w[
    member/preferences/show
    member/alerting_preferences/show
    member/telegram_connections/show
  ].freeze

  def vista(percorso)
    Rails.root.join("app/views/#{percorso}.html.erb")
  end

  describe "l'area personale si chiama «Preferenze»" do
    CYRA338_LINGUE.each do |lingua|
      it "in #{lingua} il titolo della pagina dice «#{CYRA338_PREFERENZE.fetch(lingua)}»" do
        expect(I18n.t("member.preferences.title", locale: lingua)).to eq(CYRA338_PREFERENZE.fetch(lingua))
      end

      it "in #{lingua} la voce di menu che la apre dice «#{CYRA338_PREFERENZE.fetch(lingua)}»" do
        expect(I18n.t("member.nav.preferences", locale: lingua)).to eq(CYRA338_PREFERENZE.fetch(lingua))
      end
    end

    it "le tre pagine dell'area prendono titolo e briciola di pane dalla stessa chiave" do
      fuori_posto = CYRA338_PAGINE_PERSONALI.reject do |percorso|
        testo = vista(percorso).read
        testo.include?('title: t("member.preferences.title")') &&
          testo.include?('breadcrumb: [ { label: t("member.preferences.title") } ]')
      end

      expect(fuori_posto).to be_empty,
                             "pagine dell'area personale che non si presentano come «Preferenze»: #{fuori_posto.join(', ')}"
    end

    it "nessuna pagina chiede più il vecchio nome dell'area personale" do
      residui = Dir[Rails.root.join("app/**/*.{rb,erb}")].select { |file| File.read(file).include?("member.settings.title") }

      expect(residui).to be_empty, "il vecchio titolo è ancora chiesto da: #{residui.join(', ')}"
    end

    # Il vecchio nome non deve poter rientrare da una chiave rimasta a disposizione.
    it "la chiave del vecchio titolo non esiste più" do
      CYRA338_LINGUE.each do |lingua|
        expect(I18n.exists?("member.settings.title", lingua)).to be(false)
      end
    end
  end

  describe "l'area dell'organizzazione si chiama «Amministrazione»" do
    CYRA338_LINGUE.each do |lingua|
      it "in #{lingua} l'area del menu dice «#{CYRA338_AMMINISTRAZIONE.fetch(lingua)}»" do
        expect(I18n.t("member.nav.group_settings", locale: lingua)).to eq(CYRA338_AMMINISTRAZIONE.fetch(lingua))
      end
    end

    # La pagina d'ingresso dell'area prende il nome dal gruppo: se un giorno smettesse di farlo, il
    # menu direbbe una cosa e la pagina un'altra.
    CYRA338_LINGUE.each do |lingua|
      it "in #{lingua} la pagina d'ingresso porta lo stesso nome del menu" do
        I18n.with_locale(lingua) do
          expect(Navigation::Group.find("settings").label).to eq(CYRA338_AMMINISTRAZIONE.fetch(lingua))
        end
      end
    end
  end

  describe "nessuna delle due si chiama «Impostazioni»" do
    CYRA338_LINGUE.each do |lingua|
      it "in #{lingua} i due nomi sono diversi fra loro e diversi dal nome ambiguo" do
        personale = I18n.t("member.preferences.title", locale: lingua)
        organizzazione = I18n.t("member.nav.group_settings", locale: lingua)

        expect(personale).not_to eq(organizzazione)
        expect([ personale, organizzazione ]).not_to include(CYRA338_NOME_AMBIGUO.fetch(lingua))
      end

      it "in #{lingua} nemmeno la voce di menu dell'area personale porta il nome ambiguo" do
        expect(I18n.t("member.nav.preferences", locale: lingua)).not_to eq(CYRA338_NOME_AMBIGUO.fetch(lingua))
      end
    end

    # Le guide indirizzano a voce: se continuassero a mandare al «menu Impostazioni», manderebbero a
    # un nome che nel menu non esiste più.
    CYRA338_LINGUE.each do |lingua|
      it "in #{lingua} la guida manda al menu col nome che il menu porta davvero" do
        istruzione = I18n.t("member.guides.guidance.how_org", locale: lingua)

        expect(istruzione).to include(CYRA338_AMMINISTRAZIONE.fetch(lingua))
        expect(istruzione).not_to include(CYRA338_NOME_AMBIGUO.fetch(lingua))
      end
    end
  end

  # Le schede dell'area personale stanno SOTTO il titolo dell'area: se la prima ripetesse «Preferenze»
  # si leggerebbe «Preferenze › Preferenze», e la scheda smetterebbe di dire cosa contiene.
  describe "le schede dell'area non ripetono il nome dell'area" do
    CYRA338_LINGUE.each do |lingua|
      it "in #{lingua} nessuna scheda si chiama come l'area" do
        schede = I18n.t("member.preferences.tabs", locale: lingua).values

        expect(schede).not_to include(CYRA338_PREFERENZE.fetch(lingua))
        # CYRA-643 — la quinta scheda sono gli «Accessi attivi»: sta accanto alla verifica in due
        # passaggi perché risponde alla stessa domanda, «chi può entrare col mio account?».
        expect(schede.size).to eq(5)
      end
    end
  end
end
