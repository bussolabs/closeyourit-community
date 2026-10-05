# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::LogEntries::Links", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:entry) { create(:log_entry, project:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "owner collega un errore (Attach)" do
    sign_in(owner)
    group = create(:error_group, project:)
    expect do
      post member_monitoring_log_entry_links_path(entry), params: { linkable: "Errors::Group:#{group.id}" }
    end.to change(Logs::Link, :count).by(1)
    expect(response).to redirect_to(member_monitoring_log_entry_path(entry))
  end

  it "owner scollega (Detach)" do
    sign_in(owner)
    link = create(:log_link, log_entry: entry, linkable: create(:error_group, project:))
    expect do
      delete member_monitoring_log_entry_link_path(entry, link)
    end.to change(Logs::Link, :count).by(-1)
  end

  it "Attach fallisce → alert con il messaggio del Result (ramo else di notice_or_alert)" do
    sign_in(owner)
    group = create(:error_group, project:)
    allow(Logs::Links::Attach).to receive(:call).and_return(
      Result.err(AppError.new("collegamento non valido", code: "R422-LOG-001", status: :unprocessable_content))
    )
    post member_monitoring_log_entry_links_path(entry), params: { linkable: "Errors::Group:#{group.id}" }
    expect(response).to redirect_to(member_monitoring_log_entry_path(entry))
    expect(flash[:alert]).to eq("collegamento non valido")
  end

  it "linkable malformato → alert, nessun link" do
    sign_in(owner)
    post member_monitoring_log_entry_links_path(entry), params: { linkable: "Bad::Type:x" }
    expect(flash[:alert]).to be_present
    expect(Logs::Link.count).to eq(0)
  end

  it "linkable di un altro progetto → non risolto (anti-BOLA), nessun link" do
    sign_in(owner)
    foreign_group = create(:error_group, project: create(:project, organization: org))
    expect do
      post member_monitoring_log_entry_links_path(entry), params: { linkable: "Errors::Group:#{foreign_group.id}" }
    end.not_to change(Logs::Link, :count)
    expect(flash[:alert]).to be_present
  end

  it "member senza logs.link → negato, nessun link" do
    sign_in(member)
    create(:project_membership, account: member, project: project)
    group = create(:error_group, project:)
    expect do
      post member_monitoring_log_entry_links_path(entry), params: { linkable: "Errors::Group:#{group.id}" }
    end.not_to change(Logs::Link, :count)
    expect(response).to redirect_to(root_path)
  end

  it "log non visibile → 404 (BOLA sul log)" do
    sign_in(member)
    create(:project_membership, account: member, project: project)
    foreign = create(:log_entry, project: create(:project, organization: org))
    group = create(:error_group, project: foreign.project)
    post member_monitoring_log_entry_links_path(foreign), params: { linkable: "Errors::Group:#{group.id}" }
    expect(response).to have_http_status(:not_found)
  end
end
