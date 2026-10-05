# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — la lista delle registrazioni di rilascio è la stessa per i due canali a token.
RSpec.describe Projects::Releases::Query do
  let(:project) { create(:project) }

  it "ordina dalla registrazione più recente" do
    vecchia = create(:release, project:, created_at: 2.hours.ago)
    nuova   = create(:release, project:, created_at: 1.minute.ago)

    expect(described_class.call(project:).to_a).to eq([ nuova, vecchia ])
  end

  it "resta dentro il progetto chiesto" do
    mia = create(:release, project:)
    create(:release, project: create(:project, organization: project.organization))

    expect(described_class.call(project:).to_a).to eq([ mia ])
  end
end
