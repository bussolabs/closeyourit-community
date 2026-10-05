# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::AlertNotifications", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:, role: :member) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/alert_notifications"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca SOLO le proprie notifiche in-app, con unread nel meta" do
      mine = create(:alerting_notification, organization:, account:)
      unread = create(:alerting_notification, :unread, organization:, account:)
      others = create(:alerting_notification, organization:, account: create(:account))
      email = create(:alerting_notification, :email, organization:, account:)

      get "/cli/v1/alert_notifications", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |n| n["id"] }
      expect(ids).to include(mine.id, unread.id)
      expect(ids).not_to include(others.id, email.id)
      expect(response.parsed_body["meta"]).to include("unread")
    end
  end

  describe "PUT :id/read" do
    it "marca letta la notifica → 200 e read true" do
      notification = create(:alerting_notification, :unread, organization:, account:)

      put "/cli/v1/alert_notifications/#{notification.id}/read", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["read"]).to be(true)
      expect(notification.reload.read_at).to be_present
    end

    it "notifica di un altro utente → 404 (anti-BOLA)" do
      other = create(:alerting_notification, organization:, account: create(:account))

      put "/cli/v1/alert_notifications/#{other.id}/read", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PUT read_all" do
    it "marca lette tutte le non lette → 200 con marked_read" do
      create(:alerting_notification, :unread, organization:, account:)
      create(:alerting_notification, :unread, organization:, account:)

      put "/cli/v1/alert_notifications/read_all", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["marked_read"]).to eq(2)
    end
  end

  describe "DELETE :id" do
    it "elimina la propria notifica → 204" do
      notification = create(:alerting_notification, organization:, account:)

      delete "/cli/v1/alert_notifications/#{notification.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Alerting::Notification.exists?(notification.id)).to be(false)
    end

    it "notifica di un altro utente → 404 (anti-BOLA)" do
      other = create(:alerting_notification, organization:, account: create(:account))

      delete "/cli/v1/alert_notifications/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(Alerting::Notification.exists?(other.id)).to be(true)
    end
  end
end
