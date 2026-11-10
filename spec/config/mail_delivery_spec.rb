# frozen_string_literal: true

require "rails_helper"

# Production sends through Amazon SES (config/environments/production.rb): the delivery method must exist.
RSpec.describe "Mail delivery" do
  it "registers the Amazon SES v2 delivery method" do
    expect(ActionMailer::Base.delivery_methods).to have_key(:ses_v2)
  end
end
