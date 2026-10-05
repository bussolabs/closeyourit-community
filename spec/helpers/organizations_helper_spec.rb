# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationsHelper, type: :helper do
  describe "#organization_swatch_class" do
    it "gives the same organization the same color every time" do
      organization = build_stubbed(:organization)

      expect(helper.organization_swatch_class(organization)).to eq(helper.organization_swatch_class(organization))
      expect(OrganizationsHelper::SWATCHES).to include(helper.organization_swatch_class(organization))
    end

    it "spreads different organizations over more than one color" do
      colors = Array.new(20) { helper.organization_swatch_class(build_stubbed(:organization)) }

      expect(colors.uniq.size).to be > 1
    end
  end
end
