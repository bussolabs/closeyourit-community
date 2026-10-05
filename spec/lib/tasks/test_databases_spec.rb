# frozen_string_literal: true

require "rails_helper"
require "rake"

# CYRA-587 — Il comando che si lancia a mano quando gli spazi dati di prova si sono accumulati
# (`bin/rails db:test:prune`). Qui si prova solo il collegamento: che il comando esista, che chiami
# la potatura vera e che, se questa si rifiuta, il comando si fermi invece di far finta di niente.
# Cosa si può buttare e cosa no è provato dove sta la decisione, in spec/lib/test_database_pruner*.
RSpec.describe "bin/rails db:test:prune", :silence_output do
  let(:task_name) { "db:test:prune" }

  before do
    load Rails.root.join("lib/tasks/test_databases.rake").to_s unless Rake::Task.task_defined?(task_name)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DRY_RUN").and_return(nil)
    allow(TestDatabasePruner::Sweep).to receive(:call).and_return("Nessuno spazio dati di prova da buttare.")
  end

  def run_task = Rake::Task[task_name].execute

  it "esiste" do
    expect(Rake::Task.task_defined?(task_name)).to be(true)
  end

  it "pota davvero e racconta cosa ha fatto" do
    expect { run_task }.to output(/Nessuno spazio dati/).to_stdout
    expect(TestDatabasePruner::Sweep).to have_received(:call).with(dry_run: false)
  end

  it "con DRY_RUN si limita a elencare" do
    allow(ENV).to receive(:[]).with("DRY_RUN").and_return("1")

    run_task

    expect(TestDatabasePruner::Sweep).to have_received(:call).with(dry_run: true)
  end

  it "si ferma quando la potatura si rifiuta di partire" do
    allow(TestDatabasePruner::Sweep).to receive(:call).and_raise(
      TestDatabasePruner::Sweep::Refused, "qui l'ambiente è production"
    )

    expect { run_task }.to raise_error(SystemExit).and output(/production/).to_stderr
  end
end
