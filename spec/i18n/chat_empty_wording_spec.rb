# frozen_string_literal: true

require "rails_helper"

# CYRA-447 — a elenco vuoto lo spazio delle conversazioni diceva due cose che si contraddicono
# («Ancora nessuna conversazione» nella lista e, nel pannello accanto, «Seleziona una conversazione
# per iniziare»: sceglierne una che ha appena dichiarato inesistente) e non diceva mai a cosa serva
# né in cosa differisca dai commenti su un ticket — l'unica domanda che ci si pone davanti a uno
# spazio di messaggi dentro un tracker. Qui si blinda che il testo del vuoto le risponda.
RSpec.describe "Testo del vuoto delle conversazioni (CYRA-447)", type: :model do
  # Le sole chiavi che si leggono aprendo /member/chat/conversations senza nessuna conversazione.
  CHIAVI_VUOTO_CONVERSAZIONI = %w[
    member.chat.empty
    member.chat.empty_body
    member.chat.empty_example
    member.chat.subtitle
  ].freeze

  def testo(chiave, locale) = I18n.t(chiave, locale: locale, raise: true).to_s

  it "esiste in entrambe le lingue" do
    %i[it en].each do |locale|
      CHIAVI_VUOTO_CONVERSAZIONI.each do |chiave|
        expect(testo(chiave, locale)).to be_present, "manca #{chiave} in #{locale}"
      end
    end
  end

  # È la parte che la Definition of Done chiede per esteso: senza, resta un vuoto che dichiara solo
  # di essere vuoto e lascia la domanda dov'era.
  # Page refactor (2026-10-01): the advice moved from the empty body to the page subtitle, which the
  # empty page shows too.
  it "dice quando conviene un commento sul ticket invece di una conversazione" do
    expect(testo("member.chat.subtitle", :it)).to match(/commenti del ticket/i)
    expect(testo("member.chat.empty_example", :it)).to match(/commento sul ticket/i)
    expect(testo("member.chat.subtitle", :en)).to match(/ticket comments/i)
    expect(testo("member.chat.empty_example", :en)).to match(/ticket comment/i)
  end

  # Glossario di prodotto (docs/glossario-prodotto.md): questa funzione si chiama «Conversazioni», e
  # «Chat» era il secondo nome della stessa pagina. Un testo nuovo è il posto da cui rientrerebbe.
  it "non chiama la funzione «chat»" do
    CHIAVI_VUOTO_CONVERSAZIONI.each do |chiave|
      %i[it en].each do |locale|
        expect(testo(chiave, locale)).not_to match(/\bchat\b/i), "#{chiave} (#{locale}) torna a dire «chat»"
      end
    end
  end
end
