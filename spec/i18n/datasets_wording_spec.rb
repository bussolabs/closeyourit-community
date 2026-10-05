# frozen_string_literal: true

require "rails_helper"

# CYRA-454 — la pagina dei Dataset era vuota da mesi e l'unico testo che avrebbe dovuto invogliare a
# usarla spiegava com'è fatto il dato («colonne dinamiche + foto + una colonna result», «allena un
# prompt ottimizzato»): lessico di chi costruisce modelli, non di chi coordina lavoro. Qui si blinda
# che il testo che si legge a sezione vuota parta da un problema concreto e non torni al gergo.
RSpec.describe "Lessico della sezione Dataset (CYRA-454)", type: :model do
  # Le sole chiavi che si leggono aprendo /member/datasets senza aver mai creato niente: titolo della
  # sezione vuota, esempio, chiarimento, tooltip del titolo, chip dei conteggi e stato.
  CHIAVI_VISIBILI_A_VUOTO = %w[
    member.datasets.empty
    member.datasets.empty_body
    member.datasets.empty_note
    member.datasets.empty_guide
    member.datasets.help_title
    member.datasets.counts.total
    member.datasets.counts.draft
    member.datasets.counts.trained
    member.datasets.status.draft
    member.datasets.status.trained
  ].freeze

  # Parole di chi costruisce modelli. Il confronto è su testo minuscolo e per sottostringa, così
  # cadono anche le forme flesse («allenato», «etichettate», «training»).
  GERGO_IT = %w[
    allen prompt training etichett result input target modello few-shot accuratezza
    dataset\ etichettat colonne\ dinamiche predi
  ].freeze
  GERGO_EN = %w[
    train prompt label result input target model few-shot accuracy dynamic\ columns predict
  ].freeze

  def testo(chiave, locale)
    I18n.t(chiave, locale: locale, raise: true).to_s
  end

  describe "il testo che si legge a sezione vuota non usa termini da chi costruisce modelli" do
    it "in italiano" do
      colpevoli = CHIAVI_VISIBILI_A_VUOTO.filter_map do |chiave|
        valore = testo(chiave, :it)
        parola = GERGO_IT.find { |termine| valore.downcase.include?(termine) }
        "#{chiave} contiene «#{parola}»: #{valore}" if parola
      end

      expect(colpevoli).to be_empty
    end

    it "in inglese" do
      colpevoli = CHIAVI_VISIBILI_A_VUOTO.filter_map do |chiave|
        valore = testo(chiave, :en)
        parola = GERGO_EN.find { |termine| valore.downcase.include?(termine) }
        "#{chiave} contiene «#{parola}»: #{valore}" if parola
      end

      expect(colpevoli).to be_empty
    end
  end

  # DoD 1: «Il testo della sezione vuota parte da un problema concreto dell'utente, con un esempio.»
  describe "la sezione vuota porta un esempio concreto" do
    it "l'esempio si annuncia come tale ed è una frase intera, in it e in en" do
      expect(testo("member.datasets.empty_body", :it)).to match(/esempio/i)
      expect(testo("member.datasets.empty_body", :en)).to match(/example/i)
      %w[it en].each do |locale|
        expect(testo("member.datasets.empty_body", locale).length).to be > 80
      end
    end

    # La description del ticket: «non chiarisce se abbia a che fare con gli agenti che lavorano i
    # ticket». Nel codice non c'è nessun legame — il testo deve dirlo, non lasciarlo indovinare.
    it "dice che non ha a che vedere con le macchine che lavorano i ticket" do
      expect(testo("member.datasets.empty_note", :it)).to match(/ticket/i)
      expect(testo("member.datasets.empty_note", :en)).to match(/ticket/i)
    end
  end

  # La riga del catalogo delle guide raccontava un legame con gli assistenti che nel codice non
  # esiste: nessun agente usa i dataset per lavorare i ticket.
  describe "la riga di catalogo non promette un legame con gli assistenti" do
    it "non nomina gli assistenti, in it e in en" do
      expect(testo("member.guides.catalog.datasets", :it)).not_to match(/assistent/i)
      expect(testo("member.guides.catalog.datasets", :en)).not_to match(/assistant/i)
    end
  end
end
