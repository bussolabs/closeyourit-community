require "rails_helper"

RSpec.describe "Puck channels: Telegram, Slack and the apps", type: :request do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "900", telegram_linked_at: Time.current)
      .tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let!(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(ENV).to receive(:[]).and_call_original
  end

  describe "Telegram (CYRA-1018)" do
    let(:secret) { "s3cr3t-webhook" }

    before do
      allow(ENV).to receive(:[]).with("TELEGRAM_WEBHOOK_SECRET").and_return(secret)
      allow(Telegram::Send).to receive(:call).and_return(Result.ok(true))
      allow(Telegram::Send).to receive(:api_post)
    end

    def deliver(update)
      post "/telegram/webhook", params: update.to_json,
                                headers: { "Content-Type" => "application/json", "X-Telegram-Bot-Api-Secret-Token" => secret }
    end

    it "asks the chosen Puck and answers in the same chat, with buttons for pending actions" do
      deliver(message: { text: "/puck triage", chat: { id: 900 } })
      expect(account.reload.telegram_puck_id).to eq(puck.id)
      deliver(message: { text: "/p how is SHOP?", chat: { id: 900 } })
      run = puck.runs.sole
      expect(run).to have_attributes(channel: "telegram", input: "how is SHOP?", account_id: account.id, channel_ref: { "chat_id" => "900" })

      ticket = create(:ticket, project: project)
      Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account, kind: :comment_ticket,
                                  payload: { "ticket_id" => ticket.id, "ticket_code" => ticket.code, "body" => "On it" })
      run.update!(status: "completed", output: "SHOP is fine")
      expect(Telegram::Send).to have_received(:call).with(hash_including(chat_id: "900", text: a_string_including("SHOP is fine"),
                                                                         reply_markup: hash_including(:inline_keyboard)))
    end

    it "confirms a pending action from its button, only for its owner" do
      ticket = create(:ticket, project: project)
      run = Coworkers::Start.call(puck: puck, kind: "chat", input: "x", account: account)
      proposal = Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account, kind: :comment_ticket,
                                             payload: { "ticket_id" => ticket.id, "body" => "On it" })
      deliver(callback_query: { id: "cb1", data: "cwp:c:#{proposal.id}", message: { chat: { id: 12_345 } } })
      expect(proposal.reload).to be_status_pending
      deliver(callback_query: { id: "cb2", data: "cwp:c:#{proposal.id}", message: { chat: { id: 900 } } })
      expect(proposal.reload).to be_status_confirmed
      expect(ticket.comments.sole.body).to start_with("On it")
    end
  end

  describe "Slack (CYRA-1019)" do
    let(:signing_secret) { "slack-test-secret" }

    before do
      allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(signing_secret)
      allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-test")
      allow(Coworkers::Slack).to receive(:post)
      allow(Coworkers::Slack).to receive(:thread_text).and_return("")
    end

    def deliver(payload, timestamp: Time.current.to_i, secret: signing_secret, retry_num: nil)
      body = payload.to_json
      signature = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{body}")
      post "/slack/events", params: body, headers: { "Content-Type" => "application/json", "X-Slack-Retry-Num" => retry_num,
                                                    "X-Slack-Request-Timestamp" => timestamp.to_s, "X-Slack-Signature" => signature }.compact
    end

    it "answers the URL check and refuses a bad signature or an old timestamp" do
      deliver({ type: "url_verification", challenge: "abc" })
      expect(response.parsed_body).to eq("challenge" => "abc")
      deliver({ type: "url_verification", challenge: "abc" }, secret: "wrong")
      expect(response).to have_http_status(:not_found)
      deliver({ type: "url_verification", challenge: "abc" }, timestamp: 1.hour.ago.to_i)
      expect(response).to have_http_status(:not_found)
    end

    it "links a Slack user with a code, then asks the Puck and answers in the thread" do
      code = Coworkers::Slack.link_code(account: account, organization: organization)
      perform_enqueued_jobs do
        deliver({ type: "event_callback", team_id: "T1", event_id: "E1", event: { type: "message", channel_type: "im", user: "U1", channel: "D1", ts: "1.1", text: "link #{code}" } })
      end
      expect(Coworkers::SlackLink.sole).to have_attributes(account_id: account.id, slack_user_id: "U1")
      perform_enqueued_jobs do
        deliver({ type: "event_callback", team_id: "T1", event_id: "E2", event: { type: "app_mention", user: "U1", channel: "C1", ts: "2.1", text: "<@UBOT> Triage: check SHOP" } })
      end
      run = puck.runs.sole
      expect(run).to have_attributes(channel: "slack", input: "check SHOP", channel_ref: { "channel" => "C1", "thread_ts" => "2.1" })
      run.update!(status: "completed", output: "All good")
      expect(Coworkers::Slack).to have_received(:post).with(channel: "C1", thread_ts: "2.1", text: a_string_including("All good"))
    end

    it "links only from a private message and never twice with the same code" do
      code = Coworkers::Slack.link_code(account: account, organization: organization)
      allow(Rails.cache).to receive(:write).and_call_original
      allow(Rails.cache).to receive(:write).with(/coworkers:slack-link:/, true, any_args).and_return(true, false)
      perform_enqueued_jobs do
        deliver({ type: "event_callback", team_id: "T1", event_id: "L1", event: { type: "app_mention", user: "U7", channel: "C1", ts: "1.1", text: "<@UBOT> link #{code}" } })
        expect(Coworkers::SlackLink.count).to eq(0)
        deliver({ type: "event_callback", team_id: "T1", event_id: "L2", event: { type: "message", channel_type: "im", user: "U1", channel: "D1", ts: "1.2", text: "link #{code}" } })
        deliver({ type: "event_callback", team_id: "T1", event_id: "L3", event: { type: "message", channel_type: "im", user: "U2", channel: "D2", ts: "1.3", text: "link #{code}" } })
      end
      expect(Coworkers::SlackLink.pluck(:slack_user_id)).to eq([ "U1" ])
    end

    it "starts nothing for a linked person who left the organization" do
      Coworkers::SlackLink.create!(slack_team_id: "T1", slack_user_id: "U1", account: account, organization: organization)
      Connections::Membership.where(account: account, organization: organization).delete_all
      perform_enqueued_jobs do
        deliver({ type: "event_callback", team_id: "T1", event_id: "G1", event: { type: "message", channel_type: "im", user: "U1", channel: "D1", ts: "3.1", text: "check SHOP" } })
      end
      expect(Coworkers::Run.count).to eq(0)
      expect(Coworkers::Slack).to have_received(:post).with(channel: "D1", thread_ts: "3.1", text: I18n.t("member.coworkers.slack.unavailable"))
    end

    it "tells an unlinked person how to link and ignores a repeated event" do
      perform_enqueued_jobs do
        event = { type: "event_callback", team_id: "T1", event_id: "E9", event: { type: "message", user: "U9", channel: "D9", ts: "9.1", text: "hello" } }
        deliver(event)
        deliver(event, retry_num: "1")
      end
      expect(Coworkers::Slack).to have_received(:post).once
      expect(Coworkers::Run.count).to eq(0)
    end
  end

  describe "apps API (CYRA-1022)" do
    let(:secret) { Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "App").value[:secret] }
    let(:headers) { { "Authorization" => "Bearer #{secret}" } }

    it "lists Puckies, sends a message and follows the answer" do
      get "/cli/v1/coworkers", headers: headers
      expect(response.parsed_body["data"].map { |row| row["name"] }).to eq([ "Triage" ])
      post "/cli/v1/coworkers/#{puck.id}/runs", params: { input: "Hello" }, headers: headers
      expect(response).to have_http_status(:accepted)
      id = response.parsed_body.dig("data", "id")
      Coworkers::Run.find(id).update!(status: "running", output: "Hel")
      get "/cli/v1/coworkers/#{puck.id}/runs/#{id}", headers: headers
      expect(response.parsed_body["data"]).to include("output" => "Hel", "active" => true, "channel" => "app")
    end

    it "confirms an action and never shows another person's Puck" do
      ticket = create(:ticket, project: project)
      run = Coworkers::Start.call(puck: puck, kind: "chat", input: "x", account: account)
      proposal = Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account, kind: :comment_ticket,
                                             payload: { "ticket_id" => ticket.id, "body" => "On it" })
      post "/cli/v1/coworkers/#{puck.id}/proposals/#{proposal.id}/confirm", headers: headers
      expect(response.parsed_body.dig("data", "status")).to eq("confirmed")

      stranger = create(:account)
      create(:membership, account: stranger, organization: organization, role: :member)
      hidden = Coworkers::Puck.create!(organization: organization, account: stranger, name: "Private", instructions: "x")
      get "/cli/v1/coworkers/#{hidden.id}/runs", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
