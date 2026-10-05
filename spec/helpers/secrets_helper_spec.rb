# frozen_string_literal: true

require "rails_helper"

# CYRA-426 — nelle liste che raccontano cosa è successo ai secret comparivano verbi inglesi
# («Created», «Uploaded») e, per le azioni senza voce, il testo di errore delle traduzioni.
# Qui si presidia il vocabolario unico: ogni azione che il prodotto sa registrare ha una parola
# italiana, la stessa in tutte le liste e nel registro centrale.
RSpec.describe SecretsHelper, type: :helper do
  around { |esempio| I18n.with_locale(:it) { esempio.run } }

  ogni_azione = [
    Secrets::AuditQuery::ACTIONS, Secrets::Event::ACTIONS, Secrets::AssetEvent::ACTIONS,
    Secrets::Shared::Event::ACTIONS, Secrets::Personal::Event::ACTIONS,
    Secrets::Personal::AssetEvent::ACTIONS
  ].flatten.uniq

  describe "#secret_action_label" do
    it "ha una parola italiana per ogni azione registrabile" do
      senza_voce = ogni_azione.reject { |azione| I18n.exists?("member.secrets.actions.#{azione}", :it) }

      expect(senza_voce).to be_empty
    end

    it "ha la stessa copertura in inglese" do
      senza_voce = ogni_azione.reject { |azione| I18n.exists?("member.secrets.actions.#{azione}", :en) }

      expect(senza_voce).to be_empty
    end

    it "su un'azione sconosciuta non mostra il nome tecnico né un testo di errore" do
      etichetta = helper.secret_action_label("teleported")

      expect(etichetta).to eq(I18n.t("member.secrets.actions.unknown"))
      expect(etichetta).not_to include("translation missing", "teleported", "Teleported")
    end
  end

  describe "#secret_event_sentence" do
    let(:evento) { instance_double(Secrets::Event, action: "set", name: "DATABASE_URL", metadata: { "count" => nil }) }

    it "scrive la frase dell'azione con il nome del secret" do
      expect(helper.secret_event_sentence(evento)).to eq("Modificato DATABASE_URL")
    end

    it "declina il plurale sul conteggio" do
      uno = instance_double(Secrets::Event, action: "read", name: nil, metadata: { "count" => 1 })
      tre = instance_double(Secrets::Event, action: "read", name: nil, metadata: { "count" => 3 })

      expect(helper.secret_event_sentence(uno)).to eq("Letto 1 secret")
      expect(helper.secret_event_sentence(tre)).to eq("Letti 3 secret")
    end

    it "su un'azione senza frase dedicata resta il verbo, mai il testo di errore" do
      caricato = instance_double(Secrets::Event, action: "uploaded", name: "cert.pem", metadata: {})

      expect(helper.secret_event_sentence(caricato)).to eq("Caricato")
    end
  end

  describe "#secret_event_time" do
    it "scrive il tempo in italiano e mette data e ora esatte nel tooltip" do
      istante = 3.hours.ago

      markup = helper.secret_event_time(istante)

      expect(markup).to include("ore fa")
      expect(markup).to include("title=\"#{I18n.l(istante, format: :long)}\"")
    end

    it "non scrive niente se il tempo non c'è" do
      expect(helper.secret_event_time(nil)).to be_nil
    end
  end

  # CYRA-106 — quando la sincronizzazione dei secret verso GitHub non riesce, la scheda del progetto
  # deve dire PERCHÉ e DOVE intervenire. Il motivo si sceglie dal codice dell'errore, che è nostro e
  # tradotto; il messaggio grezzo — che per un guasto di trasporto lo scrive GitHub — resta la
  # riserva per i codici che non abbiamo previsto.
  describe "#secret_sync_failure_reason" do
    def repository_con(errore)
      instance_double(Github::Repository,
                      last_sync_error_code: errore["code"], last_sync_error_message: errore["message"])
    end

    it "spiega un codice noto con parole nostre, non col messaggio interno" do
      motivo = helper.secret_sync_failure_reason(
        repository_con("code" => "R422-GITHUB-007", "message" => "riga secrets non supportata")
      )

      expect(motivo).to eq(I18n.t("member.project_github.sync_errors.R422-GITHUB-007"))
      expect(motivo).not_to include("translation missing")
    end

    it "su un codice imprevisto ripiega sul messaggio registrato" do
      motivo = helper.secret_sync_failure_reason(
        repository_con("code" => "R502-GITHUB-042", "message" => "upstream a pezzi")
      )

      expect(motivo).to eq("upstream a pezzi")
    end

    it "senza codice né messaggio dichiara che il motivo non è stato registrato" do
      motivo = helper.secret_sync_failure_reason(repository_con({}))

      expect(motivo).to eq(I18n.t("member.project_github.last_sync_unknown_reason"))
    end
  end

  describe "#secret_sync_failure_facts" do
    def repository_con(slot:, details:)
      instance_double(Github::Repository, last_sync_error_slot: slot, last_sync_error_details: details)
    end

    it "dice ambiente, file e riga che bloccano la sincronizzazione" do
      fatti = helper.secret_sync_failure_facts(
        repository_con(slot: "production", details: { "path" => ".kamal/secrets", "line" => 8 })
      )

      expect(fatti).to eq([ "Ambiente GitHub: production", "File: .kamal/secrets, riga 8" ])
    end

    it "senza numero di riga nomina il solo file" do
      fatti = helper.secret_sync_failure_facts(repository_con(slot: nil, details: { "path" => ".kamal/secrets" }))

      expect(fatti).to eq([ "File: .kamal/secrets" ])
    end

    # CYRA-637 — senza questa riga la scheda dice che la sincronizzazione si è fermata ma non quale
    # ambiente collegare, e la correzione resta da indovinare.
    it "dice quali ambienti del progetto non sono collegati al repository" do
      fatti = helper.secret_sync_failure_facts(repository_con(slot: nil, details: { "unmapped" => %w[production] }))

      expect(fatti).to eq([ "Ambienti del progetto non collegati al repository: production" ])
    end

    it "dice quali file di configurazione non si sono potuti leggere" do
      fatti = helper.secret_sync_failure_facts(
        repository_con(slot: "production", details: { "unreadable" => [ ".kamal/secrets-common" ] })
      )

      expect(fatti.last).to eq("File di configurazione che non si sono potuti leggere: .kamal/secrets-common")
    end

    it "elenca i nomi mancanti e quelli senza contenuto" do
      fatti = helper.secret_sync_failure_facts(
        repository_con(slot: nil, details: { "missing" => %w[A B], "unset" => %w[C] })
      )

      expect(fatti.first).to include("A, B")
      expect(fatti.last).to include("C")
    end

    it "senza dettagli non inventa nulla" do
      expect(helper.secret_sync_failure_facts(repository_con(slot: nil, details: {}))).to be_empty
    end
  end
end
