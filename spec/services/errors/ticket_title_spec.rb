# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — il titolo leggibile di un ticket nato da un errore (CYRA-399). È deterministico di
# proposito: la promozione parte da un clic e deve rispondere subito. Se qui si rompe, in cima alla
# colonna più letta ricompare il messaggio tecnico integrale, alto quattro righe.
RSpec.describe Errors::TicketTitle, type: :service do
  let(:project) { create(:project) }

  def title_for(title, culprit: nil)
    described_class.call(group: build(:error_group, project: project, title: title, culprit: culprit))
  end

  describe "famiglie riconosciute" do
    it "il database non risponde" do
      expect(title_for('ActiveRecord::ConnectionNotEstablished: connection to server at "10.0.0.5" failed'))
        .to eq(I18n.t("errors.ticket_title.families.database_down"))
    end

    it "tempo massimo superato" do
      expect(title_for("Net::ReadTimeout: execution expired"))
        .to eq(I18n.t("errors.ticket_title.families.timeout"))
    end

    it "dato non trovato" do
      expect(title_for("ActiveRecord::RecordNotFound: Couldn't find Account with id=7"))
        .to eq(I18n.t("errors.ticket_title.families.not_found"))
    end

    it "salvataggio rifiutato dai controlli" do
      expect(title_for("ActiveRecord::RecordInvalid: Validation failed"))
        .to eq(I18n.t("errors.ticket_title.families.invalid_data"))
    end

    it "dato mancante" do
      expect(title_for("NoMethodError: undefined method 'name' for nil"))
        .to eq(I18n.t("errors.ticket_title.families.missing_value"))
    end

    it "operazione negata" do
      expect(title_for("Pundit::NotAuthorizedError: not allowed"))
        .to eq(I18n.t("errors.ticket_title.families.forbidden"))
    end

    it "dato illeggibile" do
      expect(title_for("JSON::ParserError: unexpected token"))
        .to eq(I18n.t("errors.ticket_title.families.unreadable_input"))
    end

    # L'elenco è ordinato e la prima famiglia che combacia vince: un tipo che potrebbe cadere in due
    # famiglie non deve dipendere dall'ordine con cui capita di leggerlo.
    it "un tipo che combacia con due famiglie prende la prima dell'elenco" do
      expect(title_for("ActiveRecord::ConnectionTimeoutError: could not obtain a connection"))
        .to eq(I18n.t("errors.ticket_title.families.database_down"))
    end
  end

  describe "famiglia sconosciuta" do
    it "ricade sul nome corto dell'eccezione, senza spazio dei nomi" do
      expect(title_for("Stripe::CardError: la carta è stata rifiutata"))
        .to eq(I18n.t("errors.ticket_title.fallback", type: "CardError"))
    end

    it "titolo del gruppo vuoto → lo dichiara sconosciuto, non inventa una frase" do
      expect(title_for("")).to eq(
        I18n.t("errors.ticket_title.fallback", type: I18n.t("errors.ticket_title.unknown"))
      )
    end
  end

  describe "dove è successo" do
    it "aggiunge il file e la funzione in forma corta, senza il percorso intero" do
      titolo = title_for("Stripe::CardError: rifiutata", culprit: "app/services/checkout/pay.rb in call")
      expect(titolo).to eq(
        I18n.t("errors.ticket_title.with_location",
               subject: I18n.t("errors.ticket_title.fallback", type: "CardError"),
               location: "pay.rb · call")
      )
    end

    it "punto del codice senza funzione → solo il file, niente separatore penzolante" do
      titolo = title_for("Net::ReadTimeout: expired", culprit: "app/jobs/sync_job.rb")
      expect(titolo).to eq(
        I18n.t("errors.ticket_title.with_location",
               subject: I18n.t("errors.ticket_title.families.timeout"), location: "sync_job.rb")
      )
    end

    it "punto del codice assente → solo la frase, niente separatore penzolante" do
      expect(title_for("Net::ReadTimeout: expired", culprit: nil))
        .to eq(I18n.t("errors.ticket_title.families.timeout"))
    end

    it "punto del codice fatto di soli spazi → trattato come assente" do
      expect(title_for("Net::ReadTimeout: expired", culprit: "   "))
        .to eq(I18n.t("errors.ticket_title.families.timeout"))
    end
  end

  describe "lunghezza" do
    it "non supera mai il tetto del titolo" do
      titolo = title_for("Stripe::CardError: rifiutata", culprit: "#{'x' * 400}.rb in #{'y' * 400}")
      expect(titolo.length).to be <= described_class::MAX
    end
  end

  describe ".technical_line" do
    # Il messaggio tecnico non si perde: sparisce dal titolo e ricompare nel corpo del ticket.
    it "restituisce il titolo del gruppo integrale" do
      group = build(:error_group, project: project, title: "ActiveRecord::RecordNotFound: id=7")
      expect(described_class.technical_line(group)).to eq("ActiveRecord::RecordNotFound: id=7")
    end

    it "gruppo senza titolo → stringa vuota, mai nil nel corpo del ticket" do
      expect(described_class.technical_line(build(:error_group, project: project, title: nil))).to eq("")
    end
  end

  describe "lingua" do
    it "il titolo segue la lingua attiva" do
      inglese = I18n.with_locale(:en) { title_for("Net::ReadTimeout: expired") }
      italiano = I18n.with_locale(:it) { title_for("Net::ReadTimeout: expired") }

      expect(inglese).to eq(I18n.t("errors.ticket_title.families.timeout", locale: :en))
      expect(italiano).to eq(I18n.t("errors.ticket_title.families.timeout", locale: :it))
    end
  end

  # Il titolo del gruppo è «Tipo: messaggio»: tagliare sul primo due punti spezzerebbe a metà lo
  # spazio dei nomi dell'eccezione e nessuna famiglia combacerebbe più.
  it "riconosce la famiglia anche quando il messaggio contiene a sua volta due punti" do
    expect(title_for("ActiveRecord::RecordNotFound: Couldn't find Account: id=7"))
      .to eq(I18n.t("errors.ticket_title.families.not_found"))
  end
end
