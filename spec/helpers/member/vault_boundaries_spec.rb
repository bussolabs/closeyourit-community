# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::VaultHelper, type: :helper do
  include SecretsHelper

  it "formats activity with missing actors and optional project context" do
    row = Secrets::Event.new(action: "imported", name: nil)
    expect(helper.vault_event_actor(row)).to eq(I18n.t("member.vault_audit.system"))
    expect(helper.vault_event_line(row)).to eq(helper.secret_action_label("imported"))
    row.actor = build(:account, name: "", email: "reader@example.test")
    expect(helper.vault_event_actor(row)).to eq("reader@example.test")
    row.actor.name = "Reader"
    expect(helper.vault_event_actor(row)).to eq("Reader")
    project = build(:project, id: SecureRandom.uuid, name: "Application")
    environment = build(:environment, id: SecureRandom.uuid, label: "Testing")
    row.assign_attributes(action: "set", name: "SETTING_NAME", project_id: project.id, environment_id: environment.id)
    html = helper.vault_event_line(row, projects: { project.id => project }, environments: { environment.id => environment })
    expect(html).to include("SETTING_NAME", "Application", "vault-capability-unlock-row", "<a")
    expect(helper.vault_event_sentence(row)).to include("SETTING_NAME")
  end

  it "provides known commands and empty results for capabilities without CLI commands" do
    expect(helper.vault_capability_commands(:cli_read)).to be_present
    expect(helper.vault_capability_commands(:github_sync)).to be_present
    expect(helper.vault_capability_commands(:personal_direnv)).to be_present
    expect(helper.vault_capability_commands(:four_eyes)).to eq([])
    expect(helper.vault_capability_icon(:unknown)).to eq("circle")
    expect(helper.vault_event_capability_path(:unknown)).to be_nil
  end

  it "routes project, GitHub and personal capabilities to their own pages" do
    expect(helper.vault_capability_link(:cli_read).last).to eq("open_projects")
    expect(helper.vault_capability_link(:github_sync).last).to eq("open_project_github")
    expect(helper.vault_capability_link(:personal_direnv).last).to eq("open_personal")
    expect(helper.vault_capability_link(:unknown)).to be_nil
  end
end
