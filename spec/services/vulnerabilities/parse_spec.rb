# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Parse do
  # La fixture del lockfile Ruby si chiama `gemfile_lock.txt` e non `Gemfile.lock` di proposito:
  # il nome vero farebbe scattare gli strumenti che sorvegliano il Gemfile del progetto.
  def fixture(name) = Rails.root.join("spec/fixtures/vulnerabilities", name).read

  describe ".parser_for" do
    it "sceglie il parser dal nome file, non dall'ecosistema (npm ne ha due)" do
      expect(described_class.parser_for("Gemfile.lock")).to eq(Vulnerabilities::Parse::GemfileLock)
      expect(described_class.parser_for("web/pnpm-lock.yaml")).to eq(Vulnerabilities::Parse::PnpmLock)
      expect(described_class.parser_for("web/package-lock.json")).to eq(Vulnerabilities::Parse::NpmLock)
      expect(described_class.parser_for("app/pubspec.lock")).to eq(Vulnerabilities::Parse::PubspecLock)
      expect(described_class.parser_for("go.sum")).to eq(Vulnerabilities::Parse::GoSum)
    end

    it "nil per ciò che non sappiamo leggere" do
      expect(described_class.parser_for("uv.lock")).to be_nil
    end
  end

  it ".call solleva Parse::Error su un manifest non supportato" do
    expect { described_class.call(path: "uv.lock", content: "") }
      .to raise_error(Vulnerabilities::Parse::Error, "unsupported_manifest")
  end

  it ".call instrada al parser giusto" do
    result = described_class.call(path: "vendor-free/Gemfile.lock", content: fixture("gemfile_lock.txt"))
    expect(result.map(&:name)).to include("rails")
  end

  describe Vulnerabilities::Parse::GemfileLock do
    subject(:dependencies) { described_class.call(content: fixture("gemfile_lock.txt")) }

    it "legge tutte le gemme risolte con la versione esatta" do
      expect(dependencies.map(&:name)).to include("rails", "actionpack", "activesupport", "concurrent-ruby")
      expect(dependencies.find { |d| d.name == "actionpack" }.version).to eq("7.0.0")
    end

    it "marca dirette solo quelle dichiarate nel Gemfile" do
      expect(dependencies.find { |d| d.name == "rails" }).to be_direct
      expect(dependencies.find { |d| d.name == "concurrent-ruby" }).not_to be_direct
    end

    it "tiene anche le gemme da git, che hanno comunque una versione" do
      expect(dependencies.find { |d| d.name == "closeyourit" }.version).to eq("0.4.0")
    end

    it "un lockfile illeggibile diventa Parse::Error, non un'eccezione qualsiasi" do
      expect { described_class.call(content: "questo non è un lockfile") }
        .to raise_error(Vulnerabilities::Parse::Error)
    end
  end

  describe Vulnerabilities::Parse::PubspecLock do
    subject(:dependencies) { described_class.call(content: fixture("pubspec.lock")) }

    it "legge nome e versione dei pacchetti hosted" do
      http = dependencies.find { |d| d.name == "http" }
      expect(http.version).to eq("0.13.0")
    end

    it "«direct main» e «direct dev» sono dirette, «transitive» no" do
      expect(dependencies.find { |d| d.name == "http" }).to be_direct
      expect(dependencies.find { |d| d.name == "flutter_test" }).to be_direct
      expect(dependencies.find { |d| d.name == "_fe_analyzer_shared" }).not_to be_direct
    end

    it "salta i pacchetti locali, che non hanno una versione pubblicata" do
      expect(dependencies.map(&:name)).not_to include("local_widgets")
    end

    it "YAML malformato → Parse::Error" do
      expect { described_class.call(content: "packages:\n  - [") }
        .to raise_error(Vulnerabilities::Parse::Error)
    end

    it "un file senza la sezione packages → Parse::Error" do
      expect { described_class.call(content: "sdks:\n  dart: '3.5.0'\n") }
        .to raise_error(Vulnerabilities::Parse::Error, "missing_packages")
    end
  end

  describe Vulnerabilities::Parse::PnpmLock do
    subject(:dependencies) { described_class.call(content: fixture("pnpm-lock.yaml")) }

    it "separa nome e versione sull'ultima chiocciola (i pacchetti con scope)" do
      scoped = dependencies.find { |d| d.name == "@ampproject/remapping" }
      expect(scoped.version).to eq("2.3.0")
      expect(dependencies.find { |d| d.name == "lodash" }.version).to eq("4.17.15")
    end

    it "toglie il suffisso di peer-resolution dalla versione" do
      expect(dependencies.find { |d| d.name == "vitest" }.version).to eq("2.1.9")
    end

    it "marca dirette quelle dichiarate dagli importers, incluse le dev" do
      expect(dependencies.find { |d| d.name == "@oclif/core" }).to be_direct
      expect(dependencies.find { |d| d.name == "vitest" }).to be_direct
      expect(dependencies.find { |d| d.name == "@ampproject/remapping" }).not_to be_direct
    end

    it "scarta le voci che non hanno una versione confrontabile (tarball, link)" do
      expect(dependencies.map(&:name)).not_to include("tarball-dep")
    end
  end

  describe Vulnerabilities::Parse::NpmLock do
    subject(:dependencies) { described_class.call(content: fixture("package-lock.json")) }

    it "prende il nome dopo l'ultimo node_modules (gestisce l'annidamento)" do
      expect(dependencies.map(&:name)).to include("lodash", "vitest", "debug", "@babel/parser")
      expect(dependencies.find { |d| d.name == "debug" }.version).to eq("4.3.4")
    end

    it "il progetto stesso e i workspace collegati non sono dipendenze" do
      expect(dependencies.map(&:name)).not_to include("demo", "@demo/ui")
    end

    it "dirette = quelle dichiarate dal package.json del progetto" do
      expect(dependencies.find { |d| d.name == "lodash" }).to be_direct
      expect(dependencies.find { |d| d.name == "vitest" }).to be_direct
      expect(dependencies.find { |d| d.name == "debug" }).not_to be_direct
    end

    it "legge anche il formato v1, dove l'albero è ricorsivo" do
      legacy = {
        dependencies: {
          lodash: { version: "4.17.15", dependencies: { "nested-dep": { version: "1.0.0" } } }
        }
      }.to_json

      result = described_class.call(content: legacy)
      expect(result.find { |d| d.name == "lodash" }).to be_direct
      expect(result.find { |d| d.name == "nested-dep" }).not_to be_direct
    end

    it "JSON invalido → Parse::Error" do
      expect { described_class.call(content: "{ nope") }
        .to raise_error(Vulnerabilities::Parse::Error, "invalid_json")
    end
  end

  describe Vulnerabilities::Parse::GoSum do
    subject(:dependencies) { described_class.call(content: fixture("go.sum")) }

    it "un modulo compare una volta sola, non due per via della riga /go.mod" do
      occurrences = dependencies.count { |d| d.name == "golang.org/x/net" }
      expect(occurrences).to eq(1)
    end

    it "normalizza la versione: niente prefisso v, niente +incompatible" do
      expect(dependencies.find { |d| d.name == "golang.org/x/net" }.version).to eq("0.17.0")
      expect(dependencies.find { |d| d.name == "github.com/blang/semver" }.version).to eq("3.5.1")
    end

    it "un modulo presente col solo /go.mod non viene perso né duplicato" do
      expect(dependencies.map(&:name)).not_to include("golang.org/x/sys")
    end

    it "go.sum non sa cosa è diretto: nessuno viene marcato tale" do
      expect(dependencies).to all(have_attributes(direct: false))
    end

    it "un file vuoto dà lista vuota, non un errore" do
      expect(described_class.call(content: "")).to eq([])
    end
  end
end
