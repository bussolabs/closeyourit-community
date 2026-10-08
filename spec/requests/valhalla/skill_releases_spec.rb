# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::SkillReleases", type: :request do
  let(:god) { create(:account, god: true) }
  let!(:release) { create(:skill_release, version: "1.2.0") }

  # Same sign-in as spec/requests/valhalla/instance_updates_spec.rb: a god needs 2FA for Valhalla.
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  it "keeps non-gods out" do
    sign_in_as(create(:account))

    get "/valhalla/skills"

    expect(response).to redirect_to(root_path)
  end

  it "keeps non-gods out of the actions" do
    sign_in_as(create(:account))

    post "/valhalla/skills/sync"
    expect(response).to redirect_to(root_path)
    patch "/valhalla/skills/#{release.id}/withdraw"
    expect(response).to redirect_to(root_path)
    patch "/valhalla/skills/#{release.id}/restore"
    expect(response).to redirect_to(root_path)
    expect(release.reload).not_to be_withdrawn
  end

  context "as god" do
    before { sign_in_as(god) }

    it "lists versions" do
      get "/valhalla/skills"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("1.2.0")
    end

    it "shows the empty state when there are no versions" do
      release.destroy!

      get "/valhalla/skills"

      expect(response.body).to include("skill-releases-empty")
    end

    %w[it en].each do |locale|
      it "renders in #{locale} with the locale date format" do
        god.update!(locale:)

        get "/valhalla/skills"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.l(release.published_at.to_date, locale:))
      end
    end

    it "orders versions as versions and paginates in SQL" do
      create(:skill_release, version: "1.10.0")
      create(:skill_release, version: "1.9.0")

      get "/valhalla/skills", params: { sort: "-version" }

      body = response.body
      expect(body.index("1.10.0")).to be < body.index("1.9.0")
      expect(body.index("1.9.0")).to be < body.index("1.2.0")
    end

    it "orders by published date, then id, by default" do
      same = Time.zone.parse("2026-10-01 10:00")
      tied = [ create(:skill_release, version: "3.0.0", published_at: same), create(:skill_release, version: "3.1.0", published_at: same) ]
      release.update!(published_at: same - 1.day)

      get "/valhalla/skills"

      body = response.body
      first, second = tied.sort_by(&:id).reverse.map(&:version)
      expect(body.index(first)).to be < body.index(second)
      expect(body.index(second)).to be < body.index("1.2.0")
    end

    it "sorts by state" do
      create(:skill_release, version: "2.0.0", withdrawn_at: Time.current, published_at: release.published_at - 1.day)

      get "/valhalla/skills", params: { sort: "state" }

      expect(response.body.index("2.0.0")).to be < response.body.index("1.2.0")
    end

    it "asks confirmation before withdrawing" do
      get "/valhalla/skills"

      expect(response.body).to include("skill-release-withdraw-dialog-#{release.id}")
    end

    it "searches by version" do
      create(:skill_release, version: "2.0.0")

      get "/valhalla/skills", params: { q: "2.0.0" }

      expect(response.body).to include("2.0.0")
      expect(response.body).not_to include("1.2.0")
    end

    it "filters by state" do
      create(:skill_release, version: "2.0.0", withdrawn_at: Time.current)

      get "/valhalla/skills", params: { state: [ "withdrawn" ] }

      expect(response.body).to include("2.0.0")
      expect(response.body).not_to include("1.2.0")
    end

    it "reports a failed withdraw" do
      allow(Agents::SkillReleases::Withdraw).to receive(:call)
        .and_return(Result.err(AppError.new("cannot save", code: "R422-AGENT-001", status: :unprocessable_entity)))

      patch "/valhalla/skills/#{release.id}/withdraw"

      expect(response).to redirect_to("/valhalla/skills")
      expect(flash[:alert]).to be_present
    end

    it "withdraws and restores a version" do
      patch "/valhalla/skills/#{release.id}/withdraw"
      expect(release.reload).to be_withdrawn

      patch "/valhalla/skills/#{release.id}/restore"
      expect(release.reload).not_to be_withdrawn
    end

    it "syncs on demand and reports what it added" do
      allow(Agents::SkillReleases::Sync).to receive(:call).and_return(Result.ok(added: [ "1.3.0" ]))

      post "/valhalla/skills/sync"

      expect(response).to redirect_to("/valhalla/skills")
      expect(flash[:notice]).to include("1.3.0")
    end

    it "tells when GitHub did not answer" do
      allow(Agents::SkillReleases::Sync).to receive(:call)
        .and_return(Result.err(AppError.new("GitHub unreachable", code: "R502-AGENT-001", status: :bad_gateway)))

      post "/valhalla/skills/sync"

      expect(response).to redirect_to("/valhalla/skills")
      expect(flash[:alert]).to be_present
    end
  end
end
