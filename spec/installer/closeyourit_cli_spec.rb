# frozen_string_literal: true

require "rails_helper"

# Self-hosted day-to-day command (installer/closeyourit). Proven on a fresh Ubuntu VM for
# CYRA-914; these keep the shape that made it work.
RSpec.describe "installer/closeyourit" do
  let(:cli) { Rails.root.join("installer/closeyourit").read }

  def command(name) = cli[/^#{name}\(\) \{\n.*?^\}/m]

  it "keeps backups readable by root only (D7)" do
    expect(command("cmd_backup")).to include("install -d -m 700 backups", "chmod 600 backups/closeyourit-*.dump")
  end

  it "checks the ingest gateway and its queue when ingest is on (P5)" do
    expect(command("cmd_doctor")).to include('env_get INGEST_ENABLED)" = "true"', "for service in gateway nats")
  end

  describe "update (P6, D6)" do
    let(:update) { command("cmd_update") }

    it "downloads the release files before touching anything" do
      expect(update.index("fetch_release_files")).to be < update.index("cmd_backup")
    end

    it "tells a missing version apart from a version that does not start" do
      expect(update).to include("its files cannot be downloaded", "its images cannot be downloaded", "does not answer")
    end

    it "puts the previous files back whenever it goes back" do
      expect(update.scan("restore_release_files").size).to eq(2)
    end

    it "refreshes compose.yml, Caddyfile and the queue settings" do
      expect(cli).to include("UPDATED_FILES=(compose.yml Caddyfile ingest/nats.conf)")
    end
  end
end
