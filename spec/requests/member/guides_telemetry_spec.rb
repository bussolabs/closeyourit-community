# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telemetry guides", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account:, organization:, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  %w[it en].each do |locale|
    context "with #{locale} translations" do
      before { account.update!(locale:) }

      %w[measurements session_health].each do |slug|
        it "renders every #{slug} section and a working destination" do
          get public_send("member_guides_#{slug}_path")
          expect(response).to have_http_status(:ok)
          document = Nokogiri::HTML(response.body)
          expect(document.css("h1").size).to eq(1)
          I18n.t("member.guides.#{slug}.sections", locale:).each do |key, section|
            content = document.at_css("[data-test='guide-#{slug}-#{key}']")
            expect(content.text).to include(section.fetch(:title), section.fetch(:body))
          end
          link = document.at_css("[data-test='member-guide-#{slug.dasherize}-cta']")
          expect(link["href"]).to eq(public_send("member_monitoring_#{slug}_path"))
          expect(response.body).not_to include("translation_missing")
          expect(document.at_css("[data-test='member-guides-card-#{slug.dasherize}']")["aria-current"]).to eq("page")
        end
      end

      { "errors" => "reconstruction", "performance" => "jobs" }.each do |slug, section|
        it "renders the complete #{section} explanation" do
          get public_send("member_guides_#{slug}_path")
          expect(response).to have_http_status(:ok)
          content = Nokogiri::HTML(response.body).at_css("[data-test='member-guide-#{slug}-#{section}']")
          I18n.t("member.guides.#{slug}.#{section}", locale:).each_value do |text|
            expect(content.text).to include(text)
          end
        end
      end
    end
  end

  it "links measurement alert forms to the measurement guide" do
    expect(Guides::Map.path_for("/member/monitoring/measurements/alerts/new")).to eq(member_guides_measurements_path)
    expect(Guides::Map.path_for("/member/monitoring/sessions")).to eq(member_guides_session_health_path)
    expect(Guides::Map.path_for("/member/monitoring/replays")).to eq(member_guides_replays_path)
  end
end
