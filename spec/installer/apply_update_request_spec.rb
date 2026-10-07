# frozen_string_literal: true

require "rails_helper"
require "open3"

# The host side of "Update now" (CYRA-1035): every minute cron runs apply-update-request, which reads
# what the app left in updates/inbox. Runs the real script on a fake install; the update itself is
# replaced, since it needs Docker and root (proven on the VM instead).
RSpec.describe "closeyourit apply-update-request" do
  let(:home) { Pathname(Dir.mktmpdir) }
  let(:bin) { home.join("bin") }
  let(:script) { home.join("closeyourit") }
  let(:status_file) { home.join("updates/status/status.json") }
  let(:request_file) { home.join("updates/inbox/request") }

  def fake(name, body)
    bin.join(name).write("#!/usr/bin/env bash\n#{body}\n")
    bin.join(name).chmod(0o755)
  end

  def run_cli(*args)
    env = { "CLOSEYOURIT_HOME" => home.to_s, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
    Open3.capture2e(env, "bash", script.to_s, *args)
  end

  def status = JSON.parse(status_file.read)

  before do
    bin.mkpath
    home.join("updates/inbox").mkpath
    home.join("updates/status").mkpath
    home.join("backups").mkpath
    home.join("backups/closeyourit-20261006-120000.dump").write("")
    home.join(".env").write("CLOSEYOURIT_VERSION=1.4.2\n")
    # flock and timeout are Linux tools; docker is never reached because the update is replaced.
    fake("flock", "exit 0")
    fake("timeout", 'shift; exec "$@"')
    fake("docker", "exit 0")
    # 9.9.9 stands for a release that does not start: the real update goes back and exits 1.
    cli = Rails.root.join("installer/closeyourit").read
    script.write(cli.sub(/^case "\$\{1:-\}" in$/, "cmd_update() { [ \"$1\" != \"9.9.9\" ]; }\n\\0"))
    # Installed 755 in /usr/local/bin: it runs itself for the update.
    script.chmod(0o755)
  end

  after { FileUtils.rm_rf(home) }

  it "tells the app it is alive even without a request" do
    _, result = run_cli("apply-update-request")

    expect(result).to be_success
    expect(home.join("updates/status/heartbeat").read.to_i).to be_within(5).of(Time.now.to_i)
    expect(status_file).not_to exist
  end

  it "updates to the requested newer version and reports the backup" do
    request_file.write("1.5.0\n")

    output, result = run_cli("apply-update-request")

    expect(result).to be_success, output
    expect(request_file).not_to exist
    expect(status).to include("state" => "done", "target" => "1.5.0", "from" => "1.4.2", "backup" => "closeyourit-20261006-120000.dump")
  end

  it "reports a failed update" do
    request_file.write("9.9.9\n")

    run_cli("apply-update-request")

    expect(status).to include("state" => "failed", "target" => "9.9.9")
  end

  it "refuses to go back to an older version" do
    request_file.write("1.4.0\n")

    output, = run_cli("apply-update-request")

    expect(output).to include("refused")
    expect(request_file).not_to exist
    expect(status_file).not_to exist
  end

  it "refuses anything that is not a plain version" do
    request_file.write("1.5.0; rm -rf /\n")

    output, = run_cli("apply-update-request")

    expect(output).to include("refused")
    expect(status_file).not_to exist
  end

  it "refuses a link and never reads where it points" do
    secret = home.join("secret")
    secret.write("2.0.0\n")
    File.symlink(secret, request_file)

    output, = run_cli("apply-update-request")

    expect(output).to include("refused: the request is not a plain file")
    expect(File.symlink?(request_file)).to be(false)
    expect(secret.read).to eq("2.0.0\n")
    expect(status_file).not_to exist
  end

  it "does nothing before updates are turned on" do
    FileUtils.rm_rf(home.join("updates"))

    _, result = run_cli("apply-update-request")

    expect(result).to be_success
    expect(home.join("updates")).not_to exist
  end

  describe "the shared folders" do
    let(:compose) { Rails.root.join("installer/compose.yml").read }

    it "lets the app write requests but only read the status" do
      expect(compose).to include("./updates/inbox:/rails/updates/inbox\n", "./updates/status:/rails/updates/status:ro")
    end

    it "turns the notice on only in the community install" do
      expect(compose).to include('CLOSEYOURIT_SELF_HOSTED: "true"')
    end

    it "gives the inbox to the app user and keeps the status for root" do
      enable = Rails.root.join("installer/closeyourit").read[/^cmd_enable_updates\(\) \{\n.*?^\}/m]

      expect(enable).to include("install -d -m 755 -o root -g root updates updates/status", "install -d -m 755 -o 1000 -g 1000 updates/inbox")
    end
  end
end
