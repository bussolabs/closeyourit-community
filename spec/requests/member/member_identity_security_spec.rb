# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member recovery identity protection", type: :request do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }
  let(:victim) { create(:account, email: "victim@example.com") }
  let!(:actor_membership) { create(:membership, account: actor, organization:, role: :owner) }
  let!(:victim_membership) { create(:membership, account: victim, organization:, role: :member) }
  let!(:other_ownership) { create(:membership, account: victim, role: :owner) }

  [ :owner, :member ].each do |role|
    context "with an organization #{role}" do
      before do
        actor_membership.update!(role:)
        create(:account_permission, account: actor, organization:, permission_key: "members.edit", effect: "allow")
      end

      it "rejects changing another account's email through the web" do
        post login_path, params: { email: actor.email, password: "Secret123!" }
        patch member_member_path(victim_membership), params: { email: "attacker@example.com" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(victim.reload.email).to eq("victim@example.com")
      end

      it "rejects changing another account's email through the CLI" do
        token = Accounts::ApiTokens::Issue.call(account: actor, organization:, name: "Security test").value[:secret]
        patch "/cli/v1/members/#{victim_membership.id}",
              headers: { "Authorization" => "Bearer #{token}" }, params: { email: "attacker@example.com" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(victim.reload.email).to eq("victim@example.com")
      end
    end
  end

  it "renders the recovery email as read-only" do
    post login_path, params: { email: actor.email, password: "Secret123!" }
    get edit_member_member_path(victim_membership)

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('[data-test="member-email"][readonly]')).to be_present
  end
end
