require "rails_helper"

RSpec.describe "Member coworkers", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let!(:membership) { create(:membership, account: account, organization: organization, role: :owner) }
  let!(:puck) { Coworkers::Puck.create!(account: account, organization: organization, name: "Researcher", instructions: "Cite your sources") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "renders a real empty workspace and scoped Puck navigation" do
    get member_coworkers_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Researcher", "coworkers-sidebar", "coworkers-message")
  end

  it "creates a Puck for the current account and organization despite forged ownership" do
    post member_coworkers_path, params: { puck: { name: "Tester", instructions: "Read public sources", account_id: SecureRandom.uuid, organization_id: SecureRandom.uuid } }
    expect(response).to have_http_status(:redirect)
    expect(Coworkers::Puck.last).to have_attributes(account_id: account.id, organization_id: organization.id)
  end

  %i[account organization].each do |boundary|
    %i[read memory run approve].each do |action|
      it "rejects #{action} access across the #{boundary} boundary" do
        owner = boundary == :account ? create(:account) : account
        org = boundary == :organization ? create(:organization) : organization
        hidden = Coworkers::Puck.create!(account: owner, organization: org, name: "Private", instructions: "Private instructions")
        case action
        when :read then get member_coworker_path(hidden)
        when :memory then patch member_coworker_path(hidden), params: { puck: { memory: "Overwrite", lock_version: 0 } }
        when :run then post member_coworker_runs_path(hidden), params: { kind: "chat", input: "Read secrets" }
        when :approve then post approve_member_coworker_run_path(hidden, SecureRandom.uuid)
        end
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "rejects stale memory edits and keeps the saved version" do
    puck.update!(memory: "Approved memory")
    patch member_coworker_path(puck), params: { puck: { memory: "Stale memory", lock_version: 0 } }
    expect(puck.reload.memory).to eq("Approved memory")
    expect(flash[:alert]).to be_present
  end

  it "queues work with a memory snapshot and prevents duplicate active lanes" do
    puck.update!(memory: "Remember this")
    expect {
      post member_coworker_runs_path(puck), params: { kind: "chat", input: "Hello" }
    }.to have_enqueued_job(Coworkers::ExecuteJob)
    expect(puck.runs.last.context["approvedMemory"]).to eq("Remember this")
    expect {
      post member_coworker_runs_path(puck), params: { kind: "chat", input: "Again" }
    }.not_to change(Coworkers::Run, :count)
  end

  it "requests cancellation only through the owning Puck" do
    run = puck.runs.create!(kind: "task", input: "Research")
    patch member_coworker_run_path(puck, run)
    expect(run.reload.stop_requested).to be(true)
  end

  it "closes the feature when disabled" do
    allow(Coworkers).to receive(:enabled?).and_return(false)
    get member_coworkers_path
    expect(response).to have_http_status(:not_found)
  end

  it "requires a web session" do
    cookies.delete("session_id")
    get member_coworkers_path
    expect(response).to redirect_to(login_path)
  end

  it "rejects a run identifier belonging to another Puck" do
    other = Coworkers::Puck.create!(account: create(:account), organization: organization, name: "Other", instructions: "Cite sources")
    hidden = other.runs.create!(kind: "chat", input: "Private")
    patch member_coworker_run_path(puck, hidden)
    expect(response).to have_http_status(:not_found)
    expect(hidden.reload.stop_requested).to be(false)
  end

  it "approves once, ignores forged task input and shows progress in chat" do
    proposal = { "objective" => "Research museums", "activities" => "Read public sources", "limits" => "No writes" }
    chat = puck.runs.create!(kind: "chat", input: "Research", status: "completed", proposed_task: proposal)
    get member_coworker_path(puck)
    expect(response.body).to include("coworkers-approve", "Research museums")
    expect {
      post approve_member_coworker_run_path(puck, chat), params: { input: "Forged task" }
      # The replay repeats normal per-request authentication queries, not a production N+1.
      allow_n_plus_one { post approve_member_coworker_run_path(puck, chat), params: { input: "Forged task" } }
    }.to have_enqueued_job(Coworkers::ExecuteJob).exactly(:once)
    expect(puck.runs.where(kind: "task").count).to eq(1)
    expect(chat.reload.approved_task.input).not_to include("Forged task")
    get member_coworker_path(puck)
    expect(response.body).to include("coworkers-approved-task")
    article = Nokogiri::HTML(response.body).at_css("#coworker_run_#{chat.id}")
    expect(article.css('[role="status"]').length).to eq(1)
    expect(response.body).not_to include('data-test="coworkers-approve"')
  end

  it "rejects approval from a stale tab and a proposal belonging to another Puck" do
    chat = puck.runs.create!(kind: "chat", input: "Research", status: "completed", proposed_task: { "objective" => "Research", "activities" => "Read", "limits" => "No writes" }, proposal_superseded: true)
    expect { post approve_member_coworker_run_path(puck, chat) }.not_to have_enqueued_job
    expect(flash[:alert]).to be_present
    other = Coworkers::Puck.create!(account: account, organization: organization, name: "Other", instructions: "Read")
    post approve_member_coworker_run_path(other, chat)
    expect(response).to have_http_status(:not_found)
  end

  it "renders several proposals with task results without lazy associations or duplicate IDs" do
    3.times do
      chat = puck.runs.create!(kind: "chat", input: "Research", status: "completed", proposed_task: { "objective" => "Research", "activities" => "Read", "limits" => "No writes" })
      puck.runs.create!(kind: "task", proposal_run: chat, input: "Research", status: "completed", output: "Result")
    end
    get member_coworker_path(puck, panel: "tasks")
    expect(response).to have_http_status(:ok)
    ids = Nokogiri::HTML(response.body).css('[id^="coworker_run_"]').map { |node| node["id"] }
    expect(ids.uniq).to eq(ids)
    expect(response.body.scan('data-test="coworkers-approved-task"').length).to eq(3)
  end

  it "requires a session and an enabled feature for proposal approval" do
    chat = puck.runs.create!(kind: "chat", input: "Research", status: "completed")
    allow(Coworkers).to receive(:enabled?).and_return(false)
    expect { post approve_member_coworker_run_path(puck, chat) }.not_to have_enqueued_job
    expect(response).to have_http_status(:not_found)
    cookies.delete("session_id")
    post approve_member_coworker_run_path(puck, chat)
    expect(response).to redirect_to(login_path)
  end


  it "accepts approval with the current page CSRF header and no embedded form token" do
    chat = puck.runs.create!(kind: "chat", input: "Research", status: "completed", proposed_task: { "objective" => "Research", "activities" => "Read", "limits" => "No writes" })
    original_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get member_coworker_path(puck)
    html = Nokogiri::HTML(response.body)
    token = html.at_css('meta[name="csrf-token"]')["content"]
    button = html.at_css('[data-test="coworkers-approve"]')
    expect(button.ancestors("form").first.at_css('input[name="authenticity_token"]')).to be_nil
    post approve_member_coworker_run_path(puck, chat), headers: { "X-CSRF-Token" => token }
    expect(response).to have_http_status(:see_other)
    expect(chat.reload.approved_task).to be_present
  ensure
    ActionController::Base.allow_forgery_protection = original_protection
  end

  # F24: New and Edit Puck open in the shared modal shell, the submit in the header inside the form.
  it "opens New and Edit Puck in the standard modal shell" do
    get member_coworkers_path
    page = Nokogiri::HTML(response.body)
    { "coworkers-new-dialog" => "coworkers-create", "coworkers-edit-dialog" => "coworkers-save-puck" }.each do |dialog_id, submit_id|
      dialog = page.at_css("dialog[data-test='#{dialog_id}']")
      expect(dialog["class"]).to include("dark:bg-zinc-950", "rounded-xl")
      expect(dialog.at_css("form header [data-test='#{submit_id}']")).to be_present
      expect(dialog.at_css("form [data-test='#{dialog_id}-panel']")).to be_present
    end
  end

  describe "conversation layout (CYRA-992)" do
    def chat(input, at:, **attrs)
      puck.runs.create!(kind: "chat", input: input, status: "completed", output: "Answer to #{input}", created_at: at, **attrs)
    end

    it "opens on the last 20 messages and loads the older ones in a frame" do
      25.times { |i| chat("Message #{i}", at: (30 - i).minutes.ago) }
      get member_coworker_path(puck)
      html = Nokogiri::HTML(response.body)
      expect(html.css('[data-test="coworkers-run"]').length).to eq(20)
      expect(response.body).not_to include("Message 4<")
      link = html.at_css('[data-test="coworkers-load-older"]')
      expect(link).to be_present
      frame = link.ancestors("turbo-frame").first
      expect(frame["target"]).to eq("_top")
      expect(link["data-turbo-frame"]).to eq(frame["id"])

      get link["href"], headers: { "Turbo-Frame" => link.ancestors("turbo-frame").first["id"] }
      older = Nokogiri::HTML(response.body)
      expect(older.css('[data-test="coworkers-run"]').length).to eq(5)
      expect(response.body).to include("Message 0")
      expect(older.at_css('[data-test="coworkers-load-older"]')).to be_nil
    end

    it "separates days and keeps only the hour inside the bubbles" do
      chat("Yesterday question", at: 1.day.ago.change(hour: 10))
      chat("Today question", at: Time.current.change(hour: 9, min: 5))
      get member_coworker_path(puck)
      days = Nokogiri::HTML(response.body).css('[data-test="coworkers-day"]').map { |node| node.text.strip }
      expect(days.length).to eq(2)
      expect(response.body).to include(">09:05<")
    end

    it "retries a failed answer with the same message and refuses the others" do
      failed = chat("Find venues", at: 1.minute.ago, status: "failed", error_code: "runtime_failed")
      get member_coworker_path(puck)
      expect(response.body).to include('data-test="coworkers-retry"')
      expect {
        post repeat_member_coworker_run_path(puck, failed)
      }.to have_enqueued_job(Coworkers::ExecuteJob)
      expect(puck.runs.order(:created_at).last).to have_attributes(kind: "chat", input: "Find venues", status: "queued")

      puck.runs.active.update_all(status: "completed")
      done = chat("Done", at: 2.minutes.ago)
      post repeat_member_coworker_run_path(puck, done)
      expect(response).to have_http_status(:not_found)
    end

    it "offers copy on answers and lists tasks as cards, newest first" do
      chat("Hello", at: 3.minutes.ago)
      puck.runs.create!(kind: "task", input: "Older task", status: "completed", output: "Done", created_at: 2.hours.ago)
      puck.runs.create!(kind: "task", input: "Newer task", status: "running", created_at: 1.minute.ago)
      get member_coworker_path(puck, panel: "tasks")
      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="coworkers-copy"]')).to be_present
      titles = html.css('[data-test="coworkers-task-card"]').map { |card| card.at_css('[data-test="coworkers-task-title"]').text.strip }
      expect(titles).to eq([ "Newer task", "Older task" ])
      expect(html.css('[data-test="coworkers-panel-switch"] a').length).to eq(4) # chat, memory, tasks, rules (CYRA-1017)
    end

    it "lays the dictation strip over the message field instead of under it" do
      allow_any_instance_of(AssistantHelper).to receive(:dictation_available?).and_return(true)
      get member_coworker_path(puck)
      waves = Nokogiri::HTML(response.body).at_css('[data-test="coworkers-composer"] [data-test="dictation-waves"]')
      expect(waves["class"].split).to include("absolute", "inset-0")
      expect(waves["class"]).not_to include("mt-2")
    end

    it "previews each Puck's last answer in the sidebar without one query per Puck" do
      chat("Hi", at: 1.minute.ago, output: "Three venues found")
      other = Coworkers::Puck.create!(account: account, organization: organization, name: "Writer", instructions: "Write")
      other.runs.create!(kind: "chat", input: "Draft", status: "completed", output: "Draft ready")
      get member_coworker_path(puck)
      details = Nokogiri::HTML(response.body).css('[data-test="coworkers-sidebar"] [data-test="nav-detail"]').map(&:text)
      expect(details).to include("Three venues found", "Draft ready")
    end
  end
end
