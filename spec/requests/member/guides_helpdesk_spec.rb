# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Guides help desk", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "explains what a request is, how to turn it on, how to sort and what is kept" do
    get member_guides_helpdesk_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="member-guide-helpdesk"')
    %w[what enable read privacy].each do |section|
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.guides.helpdesk.#{section}_title")))
    end
  end

  # The guide names the switch and the permission with the words the product shows on those pages.
  it "uses the same words as the project switch and the permission" do
    get member_guides_helpdesk_path

    text = Nokogiri::HTML(response.body).text
    expect(text).to include(I18n.t("member.project_settings.helpdesk_enabled_label"))
    expect(text).to include(I18n.t("authorization.permissions")[:"helpdesk.manage"])
  end

  it "is reached from the Help desk page" do
    expect(Guides::Map.path_for("/member/helpdesk")).to eq(member_guides_helpdesk_path)
  end
end
