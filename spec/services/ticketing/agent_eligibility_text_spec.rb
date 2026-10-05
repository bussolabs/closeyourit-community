# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::AgentEligibilityText do
  def attach_png(ticket, filename: "screenshot.png")
    ticket.files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
      filename: filename,
      content_type: "image/png"
    )
    ticket.reload
  end

  describe ".call" do
    it "include titolo, tipo, descrizione e analisi tecnica" do
      ticket = create(:ticket, title: "Bottone rotto", kind: :bug,
                               description: "Non risponde al primo clic",
                               technical_analysis: "Vedi app/views/shared/_topbar.html.erb")

      text = described_class.call(ticket: ticket)

      expect(text).to include("Titolo: Bottone rotto", "Tipo: bug",
                              "Descrizione: Non risponde al primo clic",
                              "Analisi tecnica: Vedi app/views/shared/_topbar.html.erb")
    end

    it "include gli scenari BDD" do
      ticket = create(:ticket, with_default_body: false, description: "corpo")
      create(:ticketing_scenario, ticket: ticket, title: "Caso limite", step_given: "sono sulla pagina")

      text = described_class.call(ticket: ticket.reload)

      expect(text).to include("Scenari:", "Caso limite", "Given sono sulla pagina")
    end

    # È la differenza VOLUTA rispetto a EmbeddingText: un DoD che dice "droppa la tabella" è
    # esattamente il segnale che il gate cerca, mentre per l'embedding sarebbe rumore.
    it "include le condizioni di completamento, che l'embedding invece esclude" do
      ticket = create(:ticket, description: "corpo")
      create(:ticketing_condition, ticket: ticket, text: "La tabella di produzione è stata svuotata")

      text = described_class.call(ticket: ticket.reload)

      expect(text).to include("Condizioni di completamento:", "La tabella di produzione è stata svuotata")
      expect(Ticketing::EmbeddingText.call(ticket: ticket)).not_to include("La tabella di produzione")
    end

    it "omette le sezioni dei campi vuoti" do
      ticket = create(:ticket, with_default_body: false, description: "solo descrizione",
                               technical_analysis: nil)

      text = described_class.call(ticket: ticket)

      expect(text).not_to include("Scenari:", "Condizioni di completamento:", "Analisi tecnica:")
    end
  end

  describe ".checksum" do
    it "resta stabile a contenuto invariato" do
      ticket = create(:ticket, description: "corpo")

      expect(described_class.checksum(ticket: ticket)).to eq(described_class.checksum(ticket: ticket))
    end

    it "cambia quando cambia il corpo del ticket" do
      ticket = create(:ticket, description: "corpo")
      before = described_class.checksum(ticket: ticket)

      ticket.update!(description: "corpo diverso")

      expect(described_class.checksum(ticket: ticket)).not_to eq(before)
    end

    it "cambia quando cambia una condizione di completamento" do
      ticket = create(:ticket, description: "corpo")
      before = described_class.checksum(ticket: ticket)

      create(:ticketing_condition, ticket: ticket, text: "Svuota il database di produzione")

      expect(described_class.checksum(ticket: ticket.reload)).not_to eq(before)
    end

    # Il rischio può stare SOLO nell'allegato: se il fingerprint non lo coprisse, allegare uno
    # screenshot di una console di produzione a un ticket già approvato non lo rivaluterebbe.
    it "cambia quando si aggiunge un allegato, a corpo invariato" do
      ticket = create(:ticket, description: "corpo")
      before = described_class.checksum(ticket: ticket)

      attach_png(ticket)

      expect(described_class.checksum(ticket: ticket)).not_to eq(before)
    end

    it "cambia quando si rimuove un allegato" do
      ticket = create(:ticket, description: "corpo")
      attach_png(ticket)
      with_attachment = described_class.checksum(ticket: ticket)

      ticket.files.first.purge
      ticket.reload

      expect(described_class.checksum(ticket: ticket)).not_to eq(with_attachment)
    end

    it "cambia quando lo stesso file viene allegato con un nome diverso" do
      ticket = create(:ticket, description: "corpo")
      attach_png(ticket, filename: "innocuo.png")
      before = described_class.checksum(ticket: ticket)

      ticket.files.first.purge
      attach_png(ticket, filename: "console-produzione.png")

      expect(described_class.checksum(ticket: ticket)).not_to eq(before)
    end

    it "cambia per tutti i ticket al bump di PROMPT_VERSION" do
      ticket = create(:ticket, description: "corpo")
      before = described_class.checksum(ticket: ticket)

      stub_const("#{described_class}::PROMPT_VERSION", "prompt-version-test-bump")

      expect(described_class.checksum(ticket: ticket)).not_to eq(before)
    end
  end

  # CYRA-191: cambiare il SYSTEM_PROMPT senza bumpare questa versione lascerebbe i ticket già
  # valutati col vecchio verdetto — il fix non li rivaluterebbe. Il bump è la leva che rende stale
  # l'intero parco. Questo test è il promemoria: si tocca il prompt, si alza la versione.
  describe "PROMPT_VERSION" do
    it "è stata bumpata alla v2 con la revisione del prompt (CYRA-191)" do
      expect(described_class::PROMPT_VERSION).to eq("gemini-eligibility-v2")
    end
  end

  describe ".attachments_fingerprint" do
    it "è vuoto per un ticket senza allegati" do
      expect(described_class.attachments_fingerprint(ticket: create(:ticket))).to eq("")
    end

    it "non scarica i byte del blob" do
      ticket = create(:ticket, description: "corpo")
      attach_png(ticket)

      expect_any_instance_of(ActiveStorage::Blob).not_to receive(:download)
      described_class.attachments_fingerprint(ticket: ticket)
    end
  end
end
