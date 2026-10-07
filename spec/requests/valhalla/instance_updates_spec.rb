# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::InstanceUpdates", type: :request do
  let(:god) { create(:account, god: true) }
  let(:member) { create(:account) }
  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:notes) { Changelog::Parse.call("## [1.5.0] - 2026-10-20\n\n### Added\n\n- **Shared views.** Saved filters for the team.\n") }
  let(:self_hosted) { "true" }

  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  def heartbeat! = dir.join("status/heartbeat").write(Time.current.to_i.to_s)
  def status!(state, target) = dir.join("status/status.json").write({ state:, target:, from: "1.4.2", backup: "pre.dump" }.to_json)
  def page = Nokogiri::HTML(response.body)

  before do
    stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_SELF_HOSTED" => self_hosted, "CLOSEYOURIT_UPDATES_DIR" => dir.to_s, "APP_GIT_TAG" => "v1.4.2"))
    allow(Rails).to receive(:cache).and_return(cache)
    dir.join("inbox").mkpath
    dir.join("status").mkpath
    cache.write(Instance::Update::CACHE_KEY, Instance::ReleaseFeed::Release.new(version: "1.5.0", notes:))
  end

  after { FileUtils.rm_rf(dir) }

  describe "the notice" do
    it "shows the god the strip, the notes and the button when the host answers" do
      heartbeat!
      sign_in_as(god)

      get valhalla_root_path

      expect(page.at_css('[data-test="instance-update-strip"]').text).to include("1.5.0", "1.4.2")
      expect(page.at_css('[data-test="instance-update"]').text).to include("Shared views")
      expect(page.at_css('[data-test="instance-update-button"]')).to be_present
    end

    it "shows the command instead of the button when the host never answered" do
      sign_in_as(god)

      get valhalla_root_path

      expect(page.at_css('[data-test="instance-update-button"]')).to be_nil
      expect(page.at_css('[data-test="instance-update-enable"]').text).to include("closeyourit enable updates")
    end

    it "shows the strip on the member pages too" do
      sign_in_as(god)
      create(:membership, account: god)

      get root_path
      follow_redirect! while response.redirect?

      expect(page.at_css('[data-test="instance-update-strip"]')).to be_present
    end

    it "never shows anything to someone who is not god" do
      sign_in_as(member)
      create(:membership, account: member)

      get root_path
      follow_redirect! while response.redirect?

      expect(page.at_css('[data-test="instance-update-strip"]')).to be_nil
    end

    it "labels a newer release as new even right after the previous update finished" do
      heartbeat!
      status!("done", "1.4.2")
      sign_in_as(god)

      get valhalla_root_path

      expect(page.at_css('[data-test="instance-update-badge"]').text).to eq("New version")
      expect(page.at_css('[data-test="instance-update-done"]')).to be_present
    end

    it "shows the failure with the backup to put back" do
      status!("failed", "1.5.0")
      sign_in_as(god)

      get valhalla_root_path

      expect(page.at_css('[data-test="instance-update-failed"]')).to be_present
      expect(response.body).to include("sudo closeyourit restore pre.dump")
    end

    context "when the install is not a community one" do
      let(:self_hosted) { "false" }

      it "shows nothing" do
        heartbeat!
        sign_in_as(god)

        get valhalla_root_path

        expect(page.at_css('[data-test="instance-update"]')).to be_nil
        expect(page.at_css('[data-test="instance-update-strip"]')).to be_nil
      end
    end
  end

  describe "POST /valhalla/update" do
    it "leaves the request for the host" do
      heartbeat!
      sign_in_as(god)

      post valhalla_instance_update_path

      expect(response).to redirect_to(valhalla_root_path)
      expect(dir.join("inbox/request").read).to eq("1.5.0\n")
    end

    it "refuses when the host does not answer" do
      sign_in_as(god)

      post valhalla_instance_update_path

      expect(response).to redirect_to(valhalla_root_path)
      expect(flash[:alert]).to be_present
      expect(dir.join("inbox/request")).not_to exist
    end

    it "turns away someone who is not god" do
      heartbeat!
      sign_in_as(member)

      post valhalla_instance_update_path

      expect(dir.join("inbox/request")).not_to exist
    end

    context "when the install is not a community one" do
      let(:self_hosted) { "false" }

      it "answers not found" do
        heartbeat!
        sign_in_as(god)

        post valhalla_instance_update_path

        expect(response).to have_http_status(:not_found)
        expect(dir.join("inbox/request")).not_to exist
      end
    end
  end

  describe "GET /valhalla/update.json" do
    it "tells the waiting page how the update is going" do
      status!("running", "1.5.0")
      sign_in_as(god)

      get valhalla_instance_update_path(format: :json)

      expect(response.parsed_body).to eq("state" => "running", "version" => "1.4.2")
    end
  end
end
