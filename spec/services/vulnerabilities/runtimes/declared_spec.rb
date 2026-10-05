# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Runtimes::Declared do
  def parse(path, content) = described_class.call(path: path, content: content)

  describe ".file?" do
    it "riconosce i file che fissano le versioni" do
      expect(described_class).to be_file("mise.toml")
      expect(described_class).to be_file("apps/api/.tool-versions")
      expect(described_class).to be_file(".ruby-version")
      expect(described_class).not_to be_file("Gemfile")
    end
  end

  describe "mise.toml" do
    it "legge la sezione tools" do
      content = "[tools]\nruby = \"3.4.2\"\nnode = \"24.11.0\"\n"

      result = parse("mise.toml", content)

      expect(result.map { |r| [ r.name, r.version ] })
        .to contain_exactly([ "ruby", "3.4.2" ], [ "nodejs", "24.11.0" ])
    end

    it "traduce il nome nello slug del calendario pubblico" do
      expect(parse("mise.toml", "[tools]\nnode = \"24.0.0\"\n").sole.name).to eq("nodejs")
      expect(parse("mise.toml", "[tools]\ngolang = \"1.23\"\n").sole.name).to eq("go")
    end

    it "ignora ciò che non è un runtime con un calendario di supporto" do
      content = "[tools]\nnode = \"24.11.0\"\n\"npm:pnpm\" = \"11.5.2\"\nflutter = \"3.44.1\"\n"

      expect(parse("mise.toml", content).map(&:name)).to eq([ "nodejs" ])
    end

    it "ignora le righe fuori dalla sezione tools" do
      content = "[env]\nruby = \"9.9.9\"\n[tools]\nruby = \"3.4.2\"\n"

      expect(parse("mise.toml", content).sole.version).to eq("3.4.2")
    end

    it "salta commenti e righe vuote" do
      content = "# commento\n[tools]\n\n# altro\nruby = \"3.4.2\"\n"

      expect(parse("mise.toml", content).size).to eq(1)
    end

    it "vale anche per la variante nascosta .mise.toml" do
      expect(parse(".mise.toml", "[tools]\nruby = \"3.4.2\"\n").size).to eq(1)
    end
  end

  describe ".tool-versions" do
    it "legge nome e versione separati da spazi" do
      result = parse(".tool-versions", "ruby 3.4.2\nnodejs 24.11.0\n")

      expect(result.map { |r| [ r.name, r.version ] })
        .to contain_exactly([ "ruby", "3.4.2" ], [ "nodejs", "24.11.0" ])
    end

    it "tiene solo la prima versione quando ne sono elencate più d'una" do
      expect(parse(".tool-versions", "ruby 3.4.2 3.3.0\n").sole.version).to eq("3.4.2")
    end
  end

  describe ".ruby-version" do
    it "il file è la versione" do
      result = parse(".ruby-version", "4.0.5\n")

      expect(result.sole.name).to eq("ruby")
      expect(result.sole.version).to eq("4.0.5")
    end

    it "un riferimento simbolico non è una versione" do
      expect(parse(".ruby-version", "system\n")).to be_empty
      expect(parse(".ruby-version", "ruby-3.4.2\n")).to be_empty
    end
  end

  it "porta il path di provenienza, che è ciò che l'utente deve aprire per cambiarla" do
    expect(parse("apps/api/mise.toml", "[tools]\nruby = \"3.4.2\"\n").sole.source_path)
      .to eq("apps/api/mise.toml")
  end

  it "un file vuoto non dichiara niente" do
    expect(parse("mise.toml", "")).to eq([])
  end
end
