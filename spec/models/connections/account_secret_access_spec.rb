# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::AccountSecretAccess do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:account) { create(:account) }

  it "normalizza i code: spazi via, minuscoli, niente vuoti né doppioni" do
    access = create(:account_secret_access, account:, project:, organization:,
                                            environment_codes: [ " Production ", "production", "", "STAGING" ])

    expect(access.environment_codes).to eq(%w[production staging])
  end

  it "una sola riga per coppia account+progetto" do
    create(:account_secret_access, account:, project:, organization:)
    duplicate = build(:account_secret_access, account:, project:, organization:)

    expect(duplicate).not_to be_valid
  end

  it "lo stesso account può avere un override su progetti diversi" do
    other_project = create(:project, organization:)
    create(:account_secret_access, account:, project:, organization:)

    expect(build(:account_secret_access, account:, project: other_project, organization:)).to be_valid
  end

  it "rifiuta un'organizzazione diversa da quella del progetto (tenant guard)" do
    access = build(:account_secret_access, account:, project:, organization: create(:organization))

    expect(access).not_to be_valid
    expect(access.errors[:organization]).to be_present
  end

  it "il legame account/progetto/org è immutabile, la allow-list no" do
    access = create(:account_secret_access, account:, project:, organization:)

    expect { access.update!(project_id: create(:project, organization:).id) }
      .to raise_error(ActiveRecord::ReadonlyAttributeError)

    access.reload.update!(environment_codes: [ "staging" ])
    expect(access.reload.environment_codes).to eq([ "staging" ])
  end
end
