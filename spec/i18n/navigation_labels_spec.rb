# frozen_string_literal: true

require "rails_helper"

# CYRA-332 — dieci voci di menu erano rimaste senza traduzione: apparivano in inglese, col
# suggerimento del mouse che mostrava il messaggio d'errore di i18n, e nel caso peggiore il fallback
# finiva dentro un attributo `aria-label` come markup grezzo, che il lettore di schermo legge per
# intero. Le chiavi ora ci sono tutte: questa spec è la guardia perché non ne manchi più una.
#
# Non verifica le traduzioni una per una (sarebbe un elenco da aggiornare a mano, che invecchia):
# parte dai RIFERIMENTI nel codice, che sono la domanda vera — quale chiave la navigazione chiede.
RSpec.describe "Etichette di navigazione", type: :model do
  LOCALES = %i[it en].freeze

  # `t("member.nav.group_#{group.id}")` e `t("member.nav.section_#{section}")` sono interpolate: nel
  # codice restano i frammenti `group_` e `section_`, che vanno espansi sui valori reali — altrimenti
  # la spec cercherebbe una chiave che non esiste e non troverebbe quelle che mancano davvero.
  INTERPOLATE = {
    "group_" => -> { Navigation::Group.ids.map { |id| "group_#{id}" } },
    "section_" => -> { Navigation::Group::SECTIONS.map { |id| "section_#{id}" } }
  }.freeze

  def referenced_keys
    literal = Dir[Rails.root.join("app/**/*.{rb,erb}")]
              .flat_map { |file| File.read(file).scan(/member\.nav\.([a-z_0-9]+)/) }
              .flatten.uniq
    literal.flat_map { |key| INTERPOLATE.key?(key) ? INTERPOLATE.fetch(key).call : key }.uniq.sort
  end

  LOCALES.each do |locale|
    it "ogni voce di menu usata dal codice esiste in #{locale}" do
      missing = referenced_keys.reject { |key| I18n.exists?("member.nav.#{key}", locale) }

      expect(missing).to be_empty, "chiavi member.nav mancanti in #{locale}: #{missing.join(', ')}"
    end

    it "nessuna etichetta di menu in #{locale} è vuota o una traduzione mancante" do
      offenders = referenced_keys.select do |key|
        label = I18n.t("member.nav.#{key}", locale:, default: "")
        label.blank? || label.include?("translation missing") || label.include?("<span")
      end

      expect(offenders).to be_empty
    end
  end

  it "italiano e inglese hanno le stesse voci di menu" do
    it_keys = I18n.t("member.nav", locale: :it).keys.map(&:to_s).sort
    en_keys = I18n.t("member.nav", locale: :en).keys.map(&:to_s).sort

    expect(it_keys).to eq(en_keys)
  end

  # Il caso peggiore del rilievo: la chiave finiva in un attributo, dove il fallback di i18n inietta
  # markup che nessuno interpreta e il lettore di schermo pronuncia per intero.
  it "le etichette usate negli attributi non contengono markup" do
    %w[valhalla todos chat alerts toggle preferences].each do |key|
      LOCALES.each do |locale|
        label = I18n.t("member.nav.#{key}", locale:)
        expect(label).not_to include("<")
        expect(label).not_to include("translation")
      end
    end
  end

  # CYRA-333 — «Avvisi» indicava due posti diversi: la campanella (che apre le Notifiche) e la voce
  # del menu che porta alle regole. Un nome, un posto: il collegamento si chiama come la pagina che
  # apre, altrimenti chi cerca una cosa ne trova un'altra.
  describe "un nome indica un posto solo" do
    it "la campanella si chiama come la pagina delle notifiche" do
      LOCALES.each do |locale|
        expect(I18n.t("member.nav.alerts", locale:)).to eq(I18n.t("member.alerting.notifications.title", locale:))
      end
    end

    it "la voce del menu si chiama come la pagina delle regole di avviso" do
      LOCALES.each do |locale|
        expect(I18n.t("member.nav.alert_rules", locale:)).to eq(I18n.t("member.alerting.rules.title", locale:))
      end
    end

    # CYRA-315 / CYRA-658 — le colonne di notifiche in Home non esistono più, e nemmeno l'uscita in
    # fondo che le aveva sostituite. Dalla home ci si arriva dalla campanella in alto, che ha un
    # nome suo (`member.nav.alerts`): quel nome deve portare la parola della pagina a cui manda, o
    # si preme un'icona senza sapere dove si finisce.
    it "la campanella porta il nome della pagina a cui manda" do
      LOCALES.each do |locale|
        pagina = I18n.t("member.alerting.notifications.title", locale:)
        campanella = I18n.t("member.nav.alerts", locale:)
        expect(campanella.downcase).to include(pagina.downcase.split.first),
                                       "#{locale}: la campanella si chiama «#{campanella}», la pagina «#{pagina}»"
      end
    end

    # CYRA-486 — la regola che decide e la notifica che ne esce sono la coppia più vicina dell'area: se
    # le due pagine portassero lo stesso titolo, non sapresti quale delle due stai guardando.
    it "le regole di avviso e le notifiche ricevute hanno titoli di pagina distinti" do
      LOCALES.each do |locale|
        expect(I18n.t("member.alerting.rules.title", locale:)).not_to eq(I18n.t("member.alerting.notifications.title", locale:))
      end
    end
  end
end
