# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebsiteHelper, type: :helper do
  describe "#website_page_path" do
    it "risolve le pagine nei due locali (default senza suffisso, it con suffisso _it)" do
      expect(helper.website_page_path(:home)).to eq("/")
      expect(helper.website_page_path(:home, locale: :it)).to eq("/it")
      expect(helper.website_page_path(:feature, slug: "logs", locale: :it)).to eq("/it/funzionalita/logs")
      expect(helper.website_page_path(:integrations)).to eq("/integrations")
    end

    it "pagina sconosciuta → ArgumentError" do
      expect { helper.website_page_path(:nope) }.to raise_error(ArgumentError, /nope/)
    end
  end
end
