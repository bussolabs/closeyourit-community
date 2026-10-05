# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attachable do
  describe ".allowed?" do
    it "true per content-type ammesso ed entro il limite di dimensione" do
      expect(described_class.allowed?(content_type: "image/png", byte_size: 1.kilobyte)).to be(true)
    end

    it "false per content-type non ammesso" do
      expect(described_class.allowed?(content_type: "application/x-msdownload", byte_size: 1)).to be(false)
    end

    it "false per dimensione oltre il limite" do
      expect(described_class.allowed?(content_type: "image/png",
                                      byte_size: App::Constants::ATTACHMENT_MAX_SIZE + 1)).to be(false)
    end

    it "un video (mov, mp4, webm) è ammesso fino al tetto video, più alto di quello generale" do
      %w[video/quicktime video/mp4 video/webm].each do |tipo|
        expect(described_class.allowed?(content_type: tipo, byte_size: App::Constants::VIDEO_MAX_SIZE)).to be(true)
        expect(described_class.allowed?(content_type: tipo, byte_size: App::Constants::VIDEO_MAX_SIZE + 1)).to be(false)
      end
    end

    it "il tetto video non si estende agli altri tipi" do
      expect(described_class.allowed?(content_type: "image/png",
                                      byte_size: App::Constants::ATTACHMENT_MAX_SIZE + 1)).to be(false)
      expect(App::Constants::VIDEO_MAX_SIZE).to be > App::Constants::ATTACHMENT_MAX_SIZE
    end
  end

  describe "#files_within_allowed_limits (via Ticketing::Ticket)" do
    let(:ticket) { create(:ticket) }

    def attach(content_type:, filename: "f.png")
      ticket.files.attach(io: StringIO.new("data"), filename: filename, content_type: content_type)
    end

    it "file valido (tipo ammesso, entro dimensione) → nessun errore su :files" do
      attach(content_type: "image/png")
      expect(ticket).to be_valid
    end

    it "file troppo grande → errore :too_large" do
      attach(content_type: "image/png")
      ticket.files.first.blob.update_column(:byte_size, App::Constants::ATTACHMENT_MAX_SIZE + 1)
      expect(ticket.reload).not_to be_valid
      expect(ticket.errors[:files]).to be_present
    end

    it "video entro il tetto video ma oltre quello generale → valido" do
      attach(content_type: "video/quicktime", filename: "clip.mov")
      ticket.files.first.blob.update_column(:byte_size, App::Constants::ATTACHMENT_MAX_SIZE + 1)
      expect(ticket.reload).to be_valid
    end

    it "video oltre il tetto video → errore :too_large" do
      attach(content_type: "video/mp4", filename: "clip.mp4")
      ticket.files.first.blob.update_column(:byte_size, App::Constants::VIDEO_MAX_SIZE + 1)
      expect(ticket.reload).not_to be_valid
      expect(ticket.errors[:files]).to be_present
    end

    it "content-type non ammesso → errore :invalid_type" do
      attach(content_type: "application/x-msdownload", filename: "f.exe")
      expect(ticket).not_to be_valid
      expect(ticket.errors[:files]).to be_present
    end

    it "file con blob assente (race: blob nil) → saltato senza errore (guard)" do
      attach(content_type: "image/png")
      allow_any_instance_of(ActiveStorage::Attachment).to receive(:blob).and_return(nil)
      expect(ticket).to be_valid
    end
  end
end
