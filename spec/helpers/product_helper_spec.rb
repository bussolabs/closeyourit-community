# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductHelper, type: :helper do
  describe "#feature_status_icon" do
    it "dà un'icona diversa per ogni fase del ciclo di vita" do
      icons = %i[unplanned planned in_development available deprecated not_applicable].map do |category|
        helper.feature_status_icon(build(:feature_status, category: category))
      end

      expect(icons.uniq.size).to eq(6)
    end

    it "ricade su un'icona neutra se lo stato manca" do
      expect(helper.feature_status_icon(nil)).to eq("circle")
    end
  end

  describe "#release_candidate_label" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization, name: "driverone-rails") }

    it "mette il progetto nell'etichetta (il select non ha optgroup)" do
      release = create(:release, project: project, version: "2.1.0")

      expect(helper.release_candidate_label(release)).to eq("driverone-rails · 2.1.0")
    end

    it "marca la versione che gira ora" do
      release = create(:release, project: project, version: "2.1.0", current: true)

      expect(helper.release_candidate_label(release)).to include(I18n.t("member.product.cells.live"))
    end

    it "mostra l'ambiente solo quando non è produzione" do
      release = create(:release, project: project, version: "2.1.0", environment: "staging")

      expect(helper.release_candidate_label(release)).to end_with("staging")
    end
  end
end
