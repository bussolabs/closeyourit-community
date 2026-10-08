# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillReleasePin do
  it "allows one pin per organization" do
    organization = create(:organization)
    create(:skill_release_pin, organization:)

    expect(build(:skill_release_pin, organization:)).not_to be_valid
  end
end
