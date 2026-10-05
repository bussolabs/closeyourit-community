require "rails_helper"

RSpec.describe Ticketing::AttachToTicket do
  let(:org) { create(:organization) }
  let(:ticket) { create(:ticket, organization: org) }

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  it "allega file validi e ritorna ok" do
    result = described_class.call(ticket: ticket, files: [ upload("screenshot.png", "image/png") ])

    expect(result).to be_ok
    expect(ticket.reload.files).to be_attached
  end

  it "ritorna err R422-ATTACHMENT-001 quando non vengono forniti file" do
    result = described_class.call(ticket: ticket, files: [])

    expect(result).to be_err
    expect(result.error.code).to eq("R422-ATTACHMENT-001")
    expect(ticket.reload.files).not_to be_attached
  end

  it "rifiuta un tipo non ammesso dichiarato onestamente" do
    result = described_class.call(ticket: ticket, files: [ upload("diagram.svg", "image/svg+xml") ])

    expect(result).to be_err
    expect(result.error.code).to eq("R422-ATTACHMENT-001")
    expect(ticket.reload.files).not_to be_attached
  end

  it "rifiuta un content-type spoofato (svg dichiarato image/png) via sniff server-side" do
    result = described_class.call(ticket: ticket, files: [ upload("diagram.svg", "image/png") ])

    expect(result).to be_err
    expect(ticket.reload.files).not_to be_attached
  end

  describe "cronologia" do
    let(:actor) { ticket.reporter }

    it "registra `attached` con i filename" do
      expect do
        described_class.call(ticket: ticket, files: [ upload("screenshot.png", "image/png") ], actor: actor)
      end.to change(Ticketing::Event, :count).by(1)

      event = Ticketing::Event.last
      expect(event.action).to eq("attached")
      expect(event.actor).to eq(actor)
      expect(event.data["filenames"]).to eq([ "screenshot.png" ])
    end

    it "nessun file valido → nessun evento" do
      expect do
        described_class.call(ticket: ticket, files: [], actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end

    it "rollback atomico: se l'evento fallisce, il file NON resta attaccato" do
      allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
      expect do
        described_class.call(ticket: ticket, files: [ upload("screenshot.png", "image/png") ], actor: actor)
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(ticket.reload.files).not_to be_attached
    end
  end
end
