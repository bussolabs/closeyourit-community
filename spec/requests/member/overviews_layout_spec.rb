# frozen_string_literal: true

require "rails_helper"

# The area landing pages share one view: one card shape everywhere, a subtitle of their own, the
# area guide, sections not yet in use at the bottom, and a few areas with their own layout.
RSpec.describe "Member — area landing pages layout", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  describe "subtitle" do
    %w[product settings].each do |group|
      it "#{group} says what it holds instead of the same sentence as every other area" do
        sign_in(owner)

        get public_send(:"member_#{group}_path")

        subtitle = body.at_css(%([data-test="#{group}-header-subtitle"])).text.strip
        expect(subtitle).to eq(I18n.t("member.overviews.subtitles.#{group}"))
        expect(subtitle).not_to eq(I18n.t("member.overviews.subtitles.#{(%w[product settings] - [ group ]).first}"))
      end
    end
  end

  # Page headers carry no guide link (CYRA-883): the guides are reached from the guides index.
  describe "area guide" do
    %w[product settings].each do |group|
      it "#{group} does not link its guide from the header" do
        sign_in(owner)

        get public_send(:"member_#{group}_path")

        expect(body.at_css(%([data-test="#{group}-overview-guide"]))).to be_nil
      end
    end
  end

  # CYRA-927 — Observability shows them as dashed cells of its matrix; the other areas keep the section.

  describe "administration" do
    it "groups its pages in people, projects and organization" do
      sign_in(owner)

      get member_settings_path

      section = ->(key) { body.at_css(%([data-test="settings-overview-section-#{key}"])) }
      expect(section.call("people").at_css('[data-test="settings-overview-member-nav-members"]')).to be_present
      expect(section.call("people").at_css('[data-test="settings-overview-member-nav-roles"]')).to be_present
      expect(section.call("projects").at_css('[data-test="settings-overview-member-nav-platforms"]')).to be_present
      expect(section.call("organization").at_css('[data-test="settings-overview-member-nav-integrations"]')).to be_present
      expect(section.call("people").text).to include(I18n.t("member.overviews.settings_sections.people"))
    end
  end
end
