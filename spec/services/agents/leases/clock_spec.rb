# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Leases::Clock do
  describe ".current" do
    it "legge il clock PostgreSQL e ignora il clock del nodo Rails" do
      real_now = Time.current

      travel_to(real_now + 10.years) do
        expect(described_class.current).to be_within(5.seconds).of(real_now)
      end
    end
  end
end
