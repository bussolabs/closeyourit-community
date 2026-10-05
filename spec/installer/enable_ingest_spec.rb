# frozen_string_literal: true

require "rails_helper"

# The gateway image runs as uid 10001 and reads its NATS password and envelope key as files written
# 0600 by root: it crashed in a loop and every event got a 502 (CYRA-914 B5).
RSpec.describe "closeyourit enable ingest" do
  let(:enable) { Rails.root.join("installer/closeyourit").read[/^cmd_enable\(\) \{\n.*?^\}/m] }

  it "hands the gateway secrets to the gateway user" do
    expect(enable).to include("chown 10001:10001 ingest/nats_password ingest/envelope_key")
  end

  it "points Caddy at the gateway only after the gateway stays up" do
    expect(enable.index("gateway_stable")).to be < enable.index("env_set INGEST_UPSTREAM gateway:8080")
  end
end
