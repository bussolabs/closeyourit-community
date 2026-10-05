# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::LocalGate do
  it "remembers a held key until it expires" do
    described_class.hold("k", expires_in: 1.second)

    expect(described_class.held?("k")).to be(true)
    travel 2.seconds do
      expect(described_class.held?("k")).to be(false)
    end
  end

  it "forgets a released key" do
    described_class.hold("k", expires_in: 1.minute)
    described_class.release("k")

    expect(described_class.held?("k")).to be(false)
  end
end
