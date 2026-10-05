# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Manifests::Discover do
  let(:repository) { create(:github_repository, default_branch: "main") }
  let(:project) { repository.project }
  let(:client) { instance_double(Github::Client) }

  def tree(paths, truncated: false)
    entries = paths.map do |path, type|
      { "path" => path, "type" => type || "blob", "sha" => "sha-#{path}" }
    end
    { entries: entries, truncated: truncated }
  end

  def discover = described_class.call(project: project, client: client)

  it "riconosce i lockfile ovunque stiano, anche annidati" do
    allow(client).to receive(:git_tree).and_return(
      tree([ [ "Gemfile.lock" ], [ "apps/web/pnpm-lock.yaml" ], [ "mobile/pubspec.lock" ] ])
    )

    result = discover

    expect(result).to be_ok
    expect(project.vulnerability_manifests.pluck(:path))
      .to contain_exactly("Gemfile.lock", "apps/web/pnpm-lock.yaml", "mobile/pubspec.lock")
    expect(project.vulnerability_manifests.find_by(path: "mobile/pubspec.lock").ecosystem).to eq("Pub")
  end

  it "chiede l'albero del branch di default del repository" do
    allow(client).to receive(:git_tree).and_return(tree([]))

    discover

    expect(client).to have_received(:git_tree)
      .with(repository.installation.installation_id, repository.full_name, "main")
  end

  it "salva lo sha del blob, che serve a scaricarne il contenuto" do
    allow(client).to receive(:git_tree).and_return(tree([ [ "Gemfile.lock" ] ]))

    discover

    expect(project.vulnerability_manifests.sole.blob_sha).to eq("sha-Gemfile.lock")
  end

  it "ignora directory e file che non sono lockfile noti" do
    allow(client).to receive(:git_tree).and_return(
      tree([ [ "web", "tree" ], [ "README.md" ], [ "uv.lock" ], [ "Gemfile" ] ])
    )

    discover

    expect(project.vulnerability_manifests).to be_empty
  end

  it "scarta le copie di dipendenze e i worktree" do
    allow(client).to receive(:git_tree).and_return(
      tree([ [ "node_modules/x/package-lock.json" ], [ "vendor/bundle/Gemfile.lock" ],
             [ "worktrees/CYRA-1/Gemfile.lock" ], [ "Gemfile.lock" ] ])
    )

    discover

    expect(project.vulnerability_manifests.pluck(:path)).to eq([ "Gemfile.lock" ])
  end

  it "un lockfile sparito dal repository non resta a descrivere il nulla" do
    stale = create(:vulnerability_manifest, project: project, path: "old/Gemfile.lock")
    create(:vulnerability_package, manifest: stale)
    allow(client).to receive(:git_tree).and_return(tree([ [ "Gemfile.lock" ] ]))

    discover

    expect(project.vulnerability_manifests.pluck(:path)).to eq([ "Gemfile.lock" ])
    expect(Vulnerabilities::Package.count).to eq(0)
  end

  it "una seconda passata non duplica: aggiorna lo stesso manifest" do
    allow(client).to receive(:git_tree).and_return(tree([ [ "Gemfile.lock" ] ]))
    discover

    expect { discover }.not_to change(Vulnerabilities::Manifest, :count)
  end

  it "un repository vuoto o senza quel branch non cancella ciò che sappiamo" do
    known = create(:vulnerability_manifest, project: project)
    allow(client).to receive(:git_tree).and_return(nil)

    result = discover

    expect(result).to be_ok
    expect(known.reload).to be_persisted
  end

  it "un progetto senza repository collegato è un errore dichiarato, non un crash" do
    orphan = create(:project)

    result = described_class.call(project: orphan, client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-VULN-002")
  end

  it "tetto ai manifest di un monorepo patologico, con avviso nel log" do
    stub_const("Vulnerabilities::Constants::MAX_MANIFESTS_PER_PROJECT", 2)
    allow(client).to receive(:git_tree).and_return(
      tree([ [ "a/b/c/Gemfile.lock" ], [ "Gemfile.lock" ], [ "x/Gemfile.lock" ] ])
    )
    allow(Rails.logger).to receive(:warn)

    discover

    # I più vicini alla radice per primi: sono quelli che descrivono l'applicazione principale.
    expect(project.vulnerability_manifests.pluck(:path)).to contain_exactly("Gemfile.lock", "x/Gemfile.lock")
    expect(Rails.logger).to have_received(:warn).with(/3 manifest trovati, ne scansiono 2/)
  end

  it "un errore GitHub diventa Result.err col suo codice" do
    allow(client).to receive(:git_tree)
      .and_raise(Github::Client::Error.new("boom", code: "R502-GITHUB-001"))

    result = discover

    expect(result).to be_err
    expect(result.error.code).to eq("R502-GITHUB-001")
  end
end
