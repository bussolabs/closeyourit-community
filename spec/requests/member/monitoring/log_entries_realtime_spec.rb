# frozen_string_literal: true

require "rails_helper"

# Hook DOM realtime (CYRA-57): l'index espone la sottoscrizione allo stream log + il meta page-refresh
# Turbo (morph), che al broadcast di Logs::Broadcast fa ri-fetchare la PROPRIA index a ogni viewer (coi
# suoi filtri) e morphare il DOM. Sostituisce il vecchio prepend per-riga su tbody id="logs_stream". Qui
# solo render statico (la consegna live è nel service spec record_broadcast_spec / broadcast_spec).
RSpec.describe "Member::Monitoring::LogEntries realtime", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "sottoscrive lo stream log e opta al page-refresh Turbo (morph)" do
      sign_in(owner)
      entry = create(:log_entry, project:, message: "disk almost full")
      get member_monitoring_log_entries_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-cable-stream-source")                          # turbo_stream_from logs
      expect(response.body).to include('name="turbo-refresh-method"')                        # opt-in refresh Turbo 8
      expect(response.body).to include('content="morph"')                                    # morph (non replace hard)
      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(entry)}")) # riga renderizzata
      expect(response.body).to include('data-test="log-entry-row"')                          # riga renderizzata via partial
    end

    it "sottoscrive lo stream anche su lista vuota (live sempre attivo)" do
      sign_in(owner)
      get member_monitoring_log_entries_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-cable-stream-source")
    end
  end
end
