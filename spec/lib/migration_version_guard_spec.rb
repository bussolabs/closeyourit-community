# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# CYRA-589 — due rami che nascono nello stesso minuto scelgono lo stesso timestamp per la loro
# migration, e git al merge non vede nessun conflitto: sono due file diversi. Dove quella versione
# è già in `schema_migrations` la seconda migration non gira e `db:migrate` esce con successo senza
# dire niente: la tabella non c'è e lo si scopre molto dopo, da un errore che sembra non c'entrare
# (è successo due volte in un giorno solo). Dove invece i due file convivono, `db:migrate` non parte
# più per nessuno. Tardi in entrambi i casi.
#
# Nessun isolamento evita la collisione — sono due rami che scelgono lo stesso intero. Va resa
# rumorosa: questa classe è il naso che la sente, e lo fa confrontando i file, non il database
# (in CI il database del ramo è vuoto: la collisione lì non si vede).
RSpec.describe MigrationVersionGuard do
  around do |example|
    Dir.mktmpdir("migration-version-guard") do |dir|
      @repo = Pathname.new(dir)
      example.run
    end
  end

  let(:repo) { @repo }

  # Un repository vero e minuscolo: il guard interroga git, e un doppio di git proverebbe soltanto
  # che il doppio si comporta come l'ho immaginato io.
  before do
    git("init", "--initial-branch=main")
    git("config", "user.email", "prove@example.test")
    git("config", "user.name", "Prove")
    add_migration("20260101000000_create_things.rb")
    git("add", "-A")
    git("commit", "-m", "il ramo principale")
    git("checkout", "-b", "ticket/CYRA-000")
  end

  def git(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: repo.to_s)
    raise "git #{arguments.join(' ')} è fallito: #{output}" unless status.success?

    output
  end

  def add_migration(filename)
    path = repo.join("db/migrate", filename)
    path.dirname.mkpath
    path.write("class #{filename[/\A\d+_(.+)\.rb\z/, 1].camelize} < ActiveRecord::Migration[8.1]\nend\n")
  end

  def verdict(base_ref: "main")
    described_class.call(root: repo, base_ref: base_ref)
  end

  describe "una versione già presa sul ramo principale" do
    before { add_migration("20260101000000_create_other_things.rb") }

    it "si accorge della collisione" do
      expect(verdict).not_to be_clean
      expect(verdict.collisions.map(&:version)).to eq([ "20260101000000" ])
    end

    it "nomina il file del ramo e quello che ha già preso il numero" do
      collision = verdict.collisions.first

      expect(collision.incoming).to eq("20260101000000_create_other_things.rb")
      expect(collision.existing).to eq("20260101000000_create_things.rb")
      expect(collision.existing_ref).to eq("main")
    end

    it "dice la conseguenza, non solo che il numero è doppio" do
      message = verdict.message

      expect(message).to include("20260101000000_create_other_things.rb")
      expect(message).to include("non verrà eseguita")
      expect(message).to include("nessuno lo segnala")
      expect(message).to include("db:migrate")
    end

    it "spiega come si esce: un timestamp nuovo, la classe resta la stessa" do
      expect(verdict.message).to include("rinomina")
    end
  end

  describe "una versione mai usata" do
    before { add_migration("20260817120000_create_fresh_things.rb") }

    it "non alza nessun allarme" do
      expect(verdict).to be_clean
      expect(verdict.collisions).to be_empty
    end

    it "non ha niente da dire" do
      expect(verdict.message).to include("Nessuna collisione")
    end
  end

  describe "le migration già presenti sul ramo principale" do
    it "non sono una collisione con sé stesse" do
      expect(verdict).to be_clean
    end

    it "restano innocue anche quando il ramo è avanti di altri commit" do
      add_migration("20260817120000_create_fresh_things.rb")
      git("add", "-A")
      git("commit", "-m", "una migration nuova")

      expect(verdict).to be_clean
    end
  end

  describe "due migration dello stesso ramo con lo stesso numero" do
    before do
      add_migration("20260817120000_create_fresh_things.rb")
      add_migration("20260817120000_create_twin_things.rb")
    end

    it "sono lo stesso identico guasto e vengono segnalate" do
      expect(verdict).not_to be_clean
      expect(verdict.collisions.map(&:incoming)).to eq([ "20260817120000_create_twin_things.rb" ])
      expect(verdict.collisions.first.existing_ref).to be_nil
    end

    it "il messaggio dice che il numero è già preso qui, non sul ramo principale" do
      expect(verdict.message).to include("in questo ramo")
    end
  end

  describe "quando il ramo principale non è raggiungibile" do
    it "non inventa un verdetto: dichiara di non aver potuto confrontare" do
      result = verdict(base_ref: "origin/main")

      expect(result).not_to be_comparable
      expect(result.collisions).to be_empty
      expect(result.message).to include("origin/main")
      expect(result.message).to include("non ho potuto confrontare")
    end
  end

  describe "i file che non sono migration" do
    it "vengono ignorati invece di far esplodere il controllo" do
      repo.join("db/migrate/.keep").write("")
      repo.join("db/migrate/README.md").write("appunti")

      expect(verdict).to be_clean
    end
  end

  describe "senza cartella db/migrate" do
    it "non ha niente da confrontare e resta pulito" do
      repo.join("db/migrate").rmtree

      expect(verdict).to be_clean
    end
  end
end
