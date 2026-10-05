# frozen_string_literal: true

# CYRA-587 — Da quando ogni lavorazione ha il proprio spazio dati di prova (TEST_SLOT in
# config/database.yml), gli spazi restano lì anche a lavorazione chiusa: ne erano rimasti 42, tutti
# fermi allo schema del giorno in cui sono nati.
#
#   bin/rails db:test:prune              # butta gli spazi abbandonati
#   DRY_RUN=1 bin/rails db:test:prune    # dice soltanto cosa butterebbe
#
# Non tocca gli archivi in uso: chi ha una connessione aperta, i processi di parallel_tests, le
# cartelle di lavoro ancora aperte e gli spazi usati da poco restano dove sono, e il comando scrive
# per ognuno il motivo per cui l'ha risparmiato. La decisione sta in lib/test_database_pruner.rb.
namespace :db do
  namespace :test do
    desc "Butta gli spazi dati di prova abbandonati, senza toccare quelli in uso (DRY_RUN=1 per vederli soltanto)"
    task prune: :environment do
      puts TestDatabasePruner::Sweep.call(dry_run: ENV["DRY_RUN"].present?)
    rescue TestDatabasePruner::Sweep::Refused => e
      abort e.message
    end
  end
end
