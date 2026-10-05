# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::CodeReference do
  describe ".parse" do
    it "riconosce un codice, normalizzando maiuscole e spazi" do
      reference = described_class.parse("  alex-3 ")

      expect(reference.key).to eq("ALEX")
      expect(reference.number).to eq(3)
    end

    it "non impone un limite sulla lunghezza della key" do
      # Il `maximum: 4` di Projects::Project è una regola del model, non del database: una key
      # legacy più lunga deve continuare a risolvere. Chi non corrisponde a un progetto non risolve
      # comunque, quindi essere larghi qui non costa nulla.
      expect(described_class.parse("PROGETTONE-12").key).to eq("PROGETTONE")
    end

    it "non riconosce ciò che codice non è" do
      aggregate_failures do
        expect(described_class.parse("ALEX")).to be_nil
        expect(described_class.parse("ALEX-")).to be_nil
        expect(described_class.parse("ALEX-0")).to be_nil
        expect(described_class.parse("-3")).to be_nil
        expect(described_class.parse("errore di login")).to be_nil
        expect(described_class.parse(nil)).to be_nil
        expect(described_class.parse("")).to be_nil
      end
    end
  end

  describe ".resolve" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization, key: "ALEX") }
    let(:other) { create(:project, organization: organization, key: "DRFL") }

    it "risolve più codici in una sola query" do
      first = create(:ticket, project: project, organization: organization)
      second = create(:ticket, project: other, organization: organization)
      references = [
        described_class.parse("ALEX-#{first.number}"),
        described_class.parse("DRFL-#{second.number}")
      ]

      resolved = nil
      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("BEGIN", "COMMIT")
      end
      begin
        # Il conteggio copre TUTTO `resolve`, non solo il caricamento finale: azzerarlo dopo la
        # chiamata nasconderebbe la risoluzione delle key, che è proprio dove un N+1 potrebbe
        # annidarsi (un find_by per codice invece di una `where(key: [...])`).
        resolved = described_class.resolve(scope: Ticketing::Ticket.all,
                                           projects: organization.projects, references: references).to_a
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(resolved).to contain_exactly(first, second)
      # Due, non una: le key dei progetti e poi i ticket. Restano due anche con N riferimenti.
      expect(queries).to eq(2)
    end

    it "non esce dallo scope ricevuto: un ticket fuori perimetro non risolve" do
      ticket = create(:ticket, project: project, organization: organization)
      reference = described_class.parse("ALEX-#{ticket.number}")

      # Scope che esclude il ticket: è così che l'anti-BOLA del chiamante resta efficace.
      resolved = described_class.resolve(scope: Ticketing::Ticket.where.not(id: ticket.id),
                                         projects: organization.projects, references: [ reference ])

      expect(resolved).to be_empty
    end

    it "non risolve una key che non appartiene ai progetti dati" do
      elsewhere_org = create(:organization)
      elsewhere = create(:project, organization: elsewhere_org, key: "ZZZZ")
      ticket = create(:ticket, project: elsewhere, organization: elsewhere_org)
      reference = described_class.parse("ZZZZ-#{ticket.number}")

      resolved = described_class.resolve(scope: Ticketing::Ticket.all,
                                         projects: organization.projects, references: [ reference ])

      expect(resolved).to be_empty
    end

    it "senza riferimenti utili non interroga nulla" do
      aggregate_failures do
        expect(described_class.resolve(scope: Ticketing::Ticket.all, projects: organization.projects,
                                       references: [])).to be_empty
        expect(described_class.resolve(scope: Ticketing::Ticket.all, projects: organization.projects,
                                       references: [ nil ])).to be_empty
      end
    end
  end
end
