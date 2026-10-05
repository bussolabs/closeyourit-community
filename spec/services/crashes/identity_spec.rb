# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Identity do
  it "compares official Sentry UUID and Breakpad UUID-plus-age without losing the age" do
    image = { "debug_id" => "634f2904-466c-510a-cfb3-9e41b6aec544", "code_id" => "04294f636c460a51cfb39e41b6aec544ee8e227c" }
    record = { "debug_id" => "634F2904466C510ACFB39E41B6AEC5440", "code_id" => image["code_id"] }
    payload = { "debug_meta" => { "images" => [ image ] } }
    expect(described_class.compatible_build?(payload, { "modules" => [ record ] })).to be(true)
    expect(described_class.compatible_build?(payload, { "modules" => [ record.merge("debug_id" => "634F2904466C510ACFB39E41B6AEC5441") ] })).to be(false)
    image["debug_id"] += "-1"
    expect(described_class.compatible_build?(payload, { "modules" => [ record.merge("debug_id" => "634F2904466C510ACFB39E41B6AEC5441") ] })).to be(true)
    expect(record["debug_id"]).to eq("634F2904466C510ACFB39E41B6AEC5440")
  end
end
