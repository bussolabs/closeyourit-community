# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::PageLink, type: :model do
  describe "validazioni" do
    it "è valida con pagina sorgente e destinazione" do
      expect(build(:page_link)).to be_valid
    end

    it "impedisce il doppione sulla stessa coppia [page, related]" do
      link = create(:page_link)
      duplicate = build(:page_link, page: link.page, related: link.related)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:related_id]).to be_present
    end

    it "impedisce il self-link" do
      page = create(:knowledge_page)
      link = build(:page_link, page: page, related: page)
      expect(link).not_to be_valid
      expect(link.errors[:related]).to be_present
    end

    it "impedisce il collegamento tra pagine di organizzazioni diverse" do
      link = build(:page_link, page: create(:knowledge_page), related: create(:knowledge_page))
      expect(link).not_to be_valid
      expect(link.errors[:related]).to be_present
    end

    it "ammette il collegamento tra progetti diversi della stessa organizzazione" do
      organization = create(:organization)
      link = build(:page_link,
                   page: create(:knowledge_page, organization: organization),
                   related: create(:knowledge_page, organization: organization))
      expect(link).to be_valid
    end
  end

  describe ".involving" do
    it "trova il collegamento da entrambe le direzioni e non da una terza pagina" do
      link = create(:page_link)
      stranger = create(:knowledge_page, organization: link.page.project.organization)

      expect(described_class.involving(link.page)).to include(link)
      expect(described_class.involving(link.related)).to include(link)
      expect(described_class.involving(stranger)).to be_empty
    end

    it "accetta più pagine insieme" do
      first = create(:page_link)
      second = create(:page_link)

      expect(described_class.involving([ first.page, second.related ])).to contain_exactly(first, second)
    end
  end

  describe "#other_page" do
    it "ritorna il capo opposto della relazione" do
      link = create(:page_link)
      expect(link.other_page(link.page)).to eq(link.related)
      expect(link.other_page(link.related)).to eq(link.page)
    end
  end

  describe "cascade" do
    it "cade con la pagina, da entrambe le direzioni" do
      link = create(:page_link)
      expect { link.page.destroy! }.to change(described_class, :count).by(-1)

      other = create(:page_link)
      expect { other.related.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
