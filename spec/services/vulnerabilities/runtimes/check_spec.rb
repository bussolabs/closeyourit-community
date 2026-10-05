# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Runtimes::Check do
  let(:project) { create(:project) }
  let(:client) { instance_double(Vulnerabilities::Eol::Client) }
  let(:today) { Date.new(2026, 8, 10) }

  def ruby_cycles
    [
      { "cycle" => "3.4", "eol" => "2028-03-31", "latest" => "3.4.10" },
      { "cycle" => "3.0", "eol" => "2024-04-23", "latest" => "3.0.7" },
      { "cycle" => "3.2", "eol" => "2026-09-30", "latest" => "3.2.9" }
    ]
  end

  def check(files, now: today.to_time)
    described_class.call(project: project, files: files, client: client, now: now)
  end

  before { allow(client).to receive(:cycles).with("ruby").and_return(ruby_cycles) }

  it "scrive lo stato del runtime dichiarato" do
    result = check({ "mise.toml" => "[tools]\nruby = \"3.4.2\"\n" })

    expect(result).to be_ok
    status = project.vulnerability_runtime_statuses.sole
    expect(status.name).to eq("ruby")
    expect(status.version).to eq("3.4.2")
    expect(status.cycle).to eq("3.4")
    expect(status.eol_on).to eq(Date.new(2028, 3, 31))
    expect(status.latest).to eq("3.4.10")
    expect(status).to be_state_supported
  end

  it "una versione col supporto finito è fuori supporto" do
    check({ ".ruby-version" => "3.0.6\n" })

    expect(project.vulnerability_runtime_statuses.sole).to be_state_eol
  end

  it "una versione che scade a breve avvisa prima della scadenza" do
    check({ ".ruby-version" => "3.2.1\n" })

    # EOL 2026-09-30, oggi 2026-08-10: dentro la finestra di preavviso.
    expect(project.vulnerability_runtime_statuses.sole).to be_state_ending_soon
  end

  it "sceglie il ciclo più specifico, non il primo che combacia" do
    allow(client).to receive(:cycles).with("nodejs").and_return([
                                                                 { "cycle" => "24", "eol" => "2030-01-01", "latest" => "24.9.9" },
                                                                 { "cycle" => "24.1", "eol" => "2026-01-01", "latest" => "24.1.5" }
                                                               ])

    check({ "mise.toml" => "[tools]\nnode = \"24.1.0\"\n" })

    status = project.vulnerability_runtime_statuses.find_by(name: "nodejs")
    expect(status.cycle).to eq("24.1")
    expect(status).to be_state_eol
  end

  it "un prodotto che il calendario non copre resta senza data, senza inventare allarmi" do
    allow(client).to receive(:cycles).with("go").and_return(nil)

    check({ ".tool-versions" => "go 1.23.0\n" })

    status = project.vulnerability_runtime_statuses.find_by(name: "go")
    expect(status.eol_on).to be_nil
    expect(status).to be_state_supported
  end

  it "eol dichiarato come true (finito, senza data) conta come fuori supporto" do
    allow(client).to receive(:cycles).with("ruby").and_return([ { "cycle" => "3.4", "eol" => true } ])

    check({ ".ruby-version" => "3.4.2\n" })

    expect(project.vulnerability_runtime_statuses.sole).to be_state_eol
  end

  it "eol dichiarato come false (ancora supportato) non è una data" do
    allow(client).to receive(:cycles).with("ruby").and_return([ { "cycle" => "3.4", "eol" => false } ])

    check({ ".ruby-version" => "3.4.2\n" })

    status = project.vulnerability_runtime_statuses.sole
    expect(status.eol_on).to be_nil
    expect(status).to be_state_supported
  end

  it "riporta solo chi ENTRA in allarme, non chi c'era già" do
    first = check({ ".ruby-version" => "3.0.6\n" })
    expect(first.value.map(&:name)).to eq([ "ruby" ])

    second = check({ ".ruby-version" => "3.0.6\n" })
    expect(second.value).to be_empty
  end

  it "una seconda passata aggiorna la stessa riga invece di duplicarla" do
    check({ ".ruby-version" => "3.0.6\n" })
    check({ ".ruby-version" => "3.4.2\n" })

    status = project.vulnerability_runtime_statuses.sole
    expect(status.version).to eq("3.4.2")
    expect(status).to be_state_supported
  end

  it "un runtime tolto dal repository smette di lamentarsi" do
    check({ ".ruby-version" => "3.0.6\n" })

    check({ "mise.toml" => "[tools]\nnode = \"24.0.0\"\n" }.tap do
      allow(client).to receive(:cycles).with("nodejs").and_return([ { "cycle" => "24", "eol" => "2030-01-01" } ])
    end)

    expect(project.vulnerability_runtime_statuses.pluck(:name)).to eq([ "nodejs" ])
  end

  it "lo stesso runtime dichiarato in due file si conta una volta" do
    files = { ".ruby-version" => "3.4.2\n", "mise.toml" => "[tools]\nruby = \"3.4.2\"\n" }

    check(files)

    expect(project.vulnerability_runtime_statuses.count).to eq(1)
  end

  it "nessun file: niente da fare" do
    expect(check({})).to be_ok
    expect(project.vulnerability_runtime_statuses).to be_empty
  end

  it "calendario irraggiungibile: errore dichiarato, e ciò che sappiamo resta" do
    known = create(:vulnerability_runtime_status, :eol, project: project, name: "ruby")
    allow(client).to receive(:cycles)
      .and_raise(Vulnerabilities::Eol::Client::Error.new("giù", code: "R502-EOL-001"))

    result = check({ ".ruby-version" => "3.0.6\n" })

    expect(result).to be_err
    expect(result.error.code).to eq("R502-EOL-001")
    expect(known.reload).to be_state_eol
  end
end
