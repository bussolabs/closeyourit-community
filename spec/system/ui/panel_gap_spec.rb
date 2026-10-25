# frozen_string_literal: true

require "rails_helper"

# Delivery channels, Roles and Teams put 24px between the page header and their table, where every
# other page puts 8px: their panel used a top margin the flush layout did not shrink. CYRA-1111
RSpec.describe "Panels sit 8px apart on every page", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:account) do
    create(:account).tap { |acc| create(:membership, account: acc, organization: org, role: :owner) }
  end

  # Distance between the bottom of the page header panel and the top of the next panel.
  def gap_below_header
    page.evaluate_script(<<~JS)
      (() => {
        const header = document.querySelector("#main-content header");
        const panel = header.closest(".rounded-lg, .rounded-xl") || header;
        let next = panel.nextElementSibling;
        while (next && next.getBoundingClientRect().height === 0) next = next.nextElementSibling;
        return Math.round(next.getBoundingClientRect().top - panel.getBoundingClientRect().bottom);
      })()
    JS
  end

  before { sign_in_as(account) }

  [ :member_alerting_channels_path, :member_roles_path, :member_teams_path, :member_members_path ].each do |path|
    it "#{path}: 8px under the header" do
      visit public_send(path)
      expect(page).to have_css("#main-content header")

      expect(gap_below_header).to eq(8)
    end
  end
end
