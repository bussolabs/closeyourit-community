# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::CaptureWorkContext do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }
  let(:project) { ticket.project }
  let(:actor) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :member) }
  end

  describe "Scenario 1: snapshot al claim" do
    before do
      create(:guidance_reference, owner: organization, key: "org-repo", position: 0, instructions: "Clona il repo")
      create(:guidance_reference, :path, owner: project, key: "proj-path", position: 1)
      create(:guidance_procedure, owner: project, key: "setup", content: "Installa le dipendenze")
    end

    it "salva uno snapshot con payload, origine, attore, timestamp e digest che ricostruiscono le istruzioni" do
      snapshot = described_class.call(ticket: ticket, actor: actor)

      references = snapshot.payload.fetch("references")
      procedures = snapshot.payload.fetch("procedures")
      # Payload: le istruzioni consegnate.
      expect(references.map { |reference| reference["key"] }).to eq(%w[org-repo proj-path])
      expect(references.first["instructions"]).to eq("Clona il repo")
      expect(procedures.map { |procedure| procedure["content"] }).to eq([ "Installa le dipendenze" ])
      # Origine: il livello di ogni elemento.
      expect(references.map { |reference| reference["level"] }).to eq(%w[organization project])
      # Attore + timestamp + versione.
      expect(snapshot).to have_attributes(actor: actor, actor_name: actor.name, organization_id: organization.id)
      expect(snapshot.generated_at).to be_present
      expect(snapshot.payload_version).to eq(Ticketing::Constants::WORK_CONTEXT_PAYLOAD_VERSION)
      # Digest: firma verificabile del contesto consegnato, RICALCOLABILE anche dopo il round-trip in DB
      # (il jsonb riordina le chiavi: la canonicalizzazione tiene il digest stabile).
      expect(snapshot.digest).to eq(Ticketing::WorkContextSnapshot.compute_digest(snapshot.payload))
      expect(snapshot.reload.digest_matches?).to be(true)
    end

    it "registra un evento timeline sintetico, senza il contenuto delle istruzioni" do
      expect { described_class.call(ticket: ticket, actor: actor) }
        .to change { ticket.events.where(action: "work_context_captured").count }.by(1)

      event = ticket.events.find_by(action: "work_context_captured")
      expect(event.actor).to eq(actor)
      expect(event.data).to include(
        "payload_version" => Ticketing::Constants::WORK_CONTEXT_PAYLOAD_VERSION,
        "references_count" => 2, "procedures_count" => 1
      )
      expect(event.data["digest"]).to be_present
      # Niente contenuti sensibili: nel data non finiscono le istruzioni.
      expect(event.data.to_json).not_to include("Installa le dipendenze")
      expect(event.data.to_json).not_to include("Clona il repo")
    end
  end

  describe "Scenario 2: modifica successiva della guidance" do
    it "non altera lo snapshot storico e non ne crea un secondo" do
      create(:guidance_reference, owner: project, key: "iniziale")
      first = described_class.call(ticket: ticket, actor: actor)
      original_payload = first.payload.deep_dup

      # La guidance live cambia dopo la cattura.
      create(:guidance_reference, owner: project, key: "aggiunta-dopo")

      second = described_class.call(ticket: ticket, actor: actor)

      expect(second).to eq(first)
      expect(second.payload).to eq(original_payload)
      expect(second.payload.fetch("references").map { |reference| reference["key"] }).to eq(%w[iniziale])
      expect(Ticketing::WorkContextSnapshot.where(ticket: ticket).count).to eq(1)
    end

    it "non registra un secondo evento timeline sui claim successivi" do
      described_class.call(ticket: ticket, actor: actor)

      expect { described_class.call(ticket: ticket, actor: actor) }
        .not_to change { ticket.events.where(action: "work_context_captured").count }
    end
  end

  describe "Scenario 3: claim tardivo" do
    it "usa la guidance CORRENTE, non quella alla creazione del ticket" do
      # Il ticket esiste già; la guidance nasce/cambia PRIMA del claim ma DOPO la creazione del ticket.
      ticket
      create(:guidance_procedure, owner: project, key: "tardiva", content: "Regola introdotta dopo")

      snapshot = described_class.call(ticket: ticket, actor: actor)

      expect(snapshot.payload.fetch("procedures").map { |procedure| procedure["key"] }).to include("tardiva")
    end
  end

  describe "attore assente" do
    it "cattura comunque lo snapshot (host storico senza service account)" do
      snapshot = described_class.call(ticket: ticket, actor: nil)

      expect(snapshot).to be_persisted
      expect(snapshot.actor).to be_nil
      expect(snapshot.actor_name).to be_nil
    end
  end

  describe "senza guidance" do
    it "salva uno snapshot con payload vuoto, senza fallire" do
      snapshot = described_class.call(ticket: ticket, actor: actor)

      expect(snapshot.payload).to eq({ "references" => [], "procedures" => [] })
      expect(snapshot.digest).to be_present
    end
  end
end
