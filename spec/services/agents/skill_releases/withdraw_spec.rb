# spec/services/agents/skill_releases/withdraw_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillReleases::Withdraw do
  let(:actor) { create(:account) }

  it "withdraws and restores a version, recording who withdrew it" do
    release = create(:skill_release)

    described_class.call(release:, actor:)
    expect(release.reload).to have_attributes(withdrawn?: true, withdrawn_by_id: actor.id)

    described_class.call(release:, actor:, withdrawn: false)
    expect(release.reload).to have_attributes(withdrawn?: false, withdrawn_by_id: nil)
  end
end
