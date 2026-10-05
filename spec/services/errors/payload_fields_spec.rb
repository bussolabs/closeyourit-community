# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — i campi che le regole di raggruppamento leggono dal payload Sentry. Un campo letto male
# qui non si vede: la regola semplicemente non combacia, e gli errori che dovevano finire in un gruppo
# unico restano sparsi senza che nessun errore lo dica.
RSpec.describe Errors::PayloadFields, type: :service do
  def fields(payload) = described_class.call(payload: payload)

  def exception_payload(values:, **rest)
    { "exception" => { "values" => values } }.merge(rest)
  end

  describe "tipo dell'eccezione" do
    it "prende il tipo dell'ultima eccezione della catena (il punto di crash)" do
      payload = exception_payload(values: [ { "type" => "IOError" }, { "type" => "RuntimeError" } ])
      expect(fields(payload)[:exception_type]).to eq("RuntimeError")
    end

    it "senza blocco eccezioni il tipo è assente" do
      expect(fields({ "message" => "solo un messaggio" })[:exception_type]).to be_nil
    end

    it "elenco di eccezioni vuoto → tipo assente" do
      expect(fields(exception_payload(values: []))[:exception_type]).to be_nil
    end

    it "elenco di eccezioni di forma inattesa (non una lista) → tipo assente, nessuna eccezione" do
      expect(fields({ "exception" => { "values" => "boom" } })[:exception_type]).to be_nil
    end
  end

  describe "punto del codice (culprit)" do
    it "preferisce l'ultimo frame del codice dell'applicazione a quelli di libreria" do
      payload = exception_payload(values: [ { "type" => "E", "stacktrace" => { "frames" => [
        { "module" => "App::Widget", "function" => "render", "in_app" => true },
        { "module" => "Gem::Renderer", "function" => "call", "in_app" => false }
      ] } } ])

      expect(fields(payload)[:culprit]).to eq("App::Widget.render")
    end

    it "nessun frame dell'applicazione → l'ultimo frame disponibile" do
      payload = exception_payload(values: [ { "type" => "E", "stacktrace" => { "frames" => [
        { "module" => "Gem::A", "function" => "one", "in_app" => false },
        { "module" => "Gem::B", "function" => "two", "in_app" => false }
      ] } } ])

      expect(fields(payload)[:culprit]).to eq("Gem::B.two")
    end

    it "senza modulo usa il nome del file" do
      payload = exception_payload(values: [ { "type" => "E", "stacktrace" => { "frames" => [
        { "filename" => "app/services/checkout/pay.rb", "function" => "call", "in_app" => true }
      ] } } ])

      expect(fields(payload)[:culprit]).to eq("app/services/checkout/pay.rb.call")
    end

    it "frame senza funzione → resta il solo modulo, senza punto finale" do
      payload = exception_payload(values: [ { "type" => "E", "stacktrace" => { "frames" => [
        { "module" => "App::Widget", "in_app" => true }
      ] } } ])

      expect(fields(payload)[:culprit]).to eq("App::Widget")
    end

    it "traccia assente o vuota → punto del codice assente" do
      expect(fields(exception_payload(values: [ { "type" => "E" } ]))[:culprit]).to be_nil
      expect(fields(exception_payload(values: [ { "type" => "E", "stacktrace" => { "frames" => [] } } ]))[:culprit])
        .to be_nil
    end
  end

  describe "messaggio" do
    it "messaggio testuale → così com'è" do
      expect(fields({ "message" => "qualcosa è andato storto" })[:message]).to eq("qualcosa è andato storto")
    end

    it "messaggio strutturato → la versione già composta" do
      payload = { "message" => { "formatted" => "utente 42 non trovato", "message" => "utente %s non trovato" } }
      expect(fields(payload)[:message]).to eq("utente 42 non trovato")
    end

    it "messaggio strutturato senza versione composta → il modello del messaggio" do
      expect(fields({ "message" => { "message" => "utente %s non trovato" } })[:message])
        .to eq("utente %s non trovato")
    end

    it "messaggio di forma inattesa → assente, nessuna eccezione" do
      expect(fields({ "message" => [ "a" ] })[:message]).to be_nil
    end
  end

  describe "transazione" do
    it "presente → così com'è" do
      expect(fields({ "transaction" => "GET /checkout" })[:transaction]).to eq("GET /checkout")
    end

    it "stringa vuota → assente (una transazione vuota non è una transazione)" do
      expect(fields({ "transaction" => "" })[:transaction]).to be_nil
    end
  end

  describe "contratto con le regole di raggruppamento" do
    # Le chiavi tornate qui sono i valori dell'enum del campo di una regola: se le due liste divergono,
    # una regola punta a un campo che non arriva mai e non combacia più con niente.
    it "torna esattamente i campi su cui una regola può essere scritta" do
      expect(fields({}).keys.map(&:to_s)).to match_array(Errors::GroupingRule.fields.keys)
    end

    it "payload assente → tutti i campi assenti, nessuna eccezione" do
      expect(fields(nil).values).to all(be_nil)
    end
  end
end
