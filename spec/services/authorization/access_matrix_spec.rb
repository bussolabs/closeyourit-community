# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authorization::AccessMatrix do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account: account, organization: org, role: :member) }

  def role_with(name, *keys)
    role = create(:role, organization: org, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  it "concede una chiave scoped solo sul progetto in scope" do
    p_in  = create(:project, organization: org)
    p_out = create(:project, organization: org)
    create(:account_role, account: account, organization: org, role: role_with("Maint", "tickets.edit"))
    create(:project_membership, account: account, project: p_in)

    snap = described_class.call(account: account, organization: org, projects: [ p_in, p_out ])

    expect(snap.keys_for(p_in.id)).to include("tickets.edit")
    expect(snap.keys_for(p_out.id)).to be_empty
  end

  it "espone le chiavi org-level indipendenti dallo scope" do
    create(:account_role, account: account, organization: org, role: role_with("People", "members.invite"))

    snap = described_class.call(account: account, organization: org, projects: [])

    expect(snap.org_keys).to include("members.invite")
    expect(snap.org_keys).not_to include("permissions.manage")
  end

  it "owner ha ogni chiave scoped su ogni progetto e ogni org-level" do
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    project = create(:project, organization: org)

    snap = described_class.call(account: owner, organization: org, projects: [ project ])

    expect(snap.keys_for(project.id)).to include("tickets.edit", "tickets.delete")
    expect(snap.org_keys).to include("organization.manage")
  end

  it "un progetto senza accesso ha insieme di chiavi vuoto" do
    project = create(:project, organization: org)
    snap = described_class.call(account: account, organization: org, projects: [ project ])
    expect(snap.keys_for(project.id)).to be_empty
  end
end
