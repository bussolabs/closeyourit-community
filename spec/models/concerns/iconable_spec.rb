# frozen_string_literal: true

require "rails_helper"

RSpec.describe Iconable do
  def attach_png(record)
    record.icon_image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
      filename: "icon.png", content_type: "image/png"
    )
  end

  describe "icon normalization" do
    it "strips spaces and lowers the case" do
      project = build(:project, icon: "  Rocket ")
      project.valid?
      expect(project.icon).to eq("rocket")
    end

    # CYRA-926 — scripts written before Lucide still send Font Awesome names through the CLI.
    it "turns an old Font Awesome name, with or without the fa- prefix, into its Lucide name" do
      project = build(:project, icon: "fa-gauge-high")
      project.valid?
      expect(project.icon).to eq("gauge")
    end

    it "porta a nil una stringa di soli spazi" do
      project = build(:project, icon: "   ")
      project.valid?
      expect(project.icon).to be_nil
    end
  end

  describe "validazione icon (inclusion nel set curato)" do
    it "accetta un nome presente in Ui::Icons::NAMES" do
      expect(build(:project, icon: "rocket")).to be_valid
    end

    it "rifiuta un nome fuori dal set" do
      project = build(:project, icon: "not-an-icon")
      expect(project).not_to be_valid
      expect(project.errors[:icon]).to be_present
    end

    it "accetta nil (icona opzionale)" do
      expect(build(:project, icon: nil)).to be_valid
    end

    it "vale anche per i gruppi" do
      expect(build(:group, icon: "not-an-icon")).not_to be_valid
    end
  end

  describe "validazione icon_image" do
    it "accetta un'immagine PNG valida" do
      project = build(:project)
      attach_png(project)
      expect(project).to be_valid
    end

    it "rifiuta un content-type non immagine" do
      project = build(:project)
      project.icon_image.attach(io: StringIO.new("hello"), filename: "x.txt", content_type: "text/plain")
      expect(project).not_to be_valid
      expect(project.errors[:icon_image]).to be_present
    end

    it "rifiuta un SVG (vettoriale: rischio XSS stored, servito inline same-origin)" do
      project = build(:project)
      project.icon_image.attach(io: StringIO.new("<svg/>"), filename: "x.svg", content_type: "image/svg+xml")
      expect(project).not_to be_valid
      expect(project.errors[:icon_image]).to be_present
    end

    it "rifiuta un'immagine oltre il limite di dimensione (:too_large)" do
      project = create(:project)
      attach_png(project)
      project.icon_image.blob.update_column(:byte_size, App::Constants::ICON_IMAGE_MAX_SIZE + 1)
      expect(project.reload).not_to be_valid
      expect(project.errors[:icon_image]).to be_present
    end

    it "blob assente (race: blob nil) → validazione saltata senza errore (guard)" do
      project = create(:project)
      attach_png(project)
      allow_any_instance_of(ActiveStorage::Attachment).to receive(:blob).and_return(nil)
      expect(project.reload).to be_valid
    end
  end

  describe ".allowed_image?" do
    it "è true per un'immagine ammessa entro il limite" do
      expect(described_class.allowed_image?(content_type: "image/png", byte_size: 500.kilobytes)).to be true
    end

    it "è false oltre la dimensione massima" do
      expect(described_class.allowed_image?(content_type: "image/png", byte_size: 5.megabytes)).to be false
    end

    it "è false per un content-type non ammesso" do
      expect(described_class.allowed_image?(content_type: "application/pdf", byte_size: 1.kilobyte)).to be false
    end

    it "è false per SVG (solo raster: evita XSS vettoriale servito inline)" do
      expect(described_class.allowed_image?(content_type: "image/svg+xml", byte_size: 1.kilobyte)).to be false
    end
  end

  describe "#icon_kind" do
    it "è :none senza icona né immagine" do
      expect(build(:project, icon: nil).icon_kind).to eq(:none)
    end

    it "is :glyph with only an icon name" do
      expect(build(:project, icon: "rocket").icon_kind).to eq(:glyph)
    end

    it "è :image quando c'è un'immagine, con precedenza sull'icona FA" do
      project = build(:project, icon: "rocket")
      attach_png(project)
      expect(project.icon_kind).to eq(:image)
    end
  end
end
