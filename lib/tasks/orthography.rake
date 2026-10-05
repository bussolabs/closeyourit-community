# frozen_string_literal: true

# Ripasso dell'ortografia italiana sui testi già in tabella (CYRA-411).
#
# Le `normalizes` dei model correggono ciò che si salva da adesso in poi; questo task sistema quello
# che le automazioni avevano già scritto — «nasce gia in stato saltata, che e definitivo».
#
#   bin/rails orthography:fix                 # DRY RUN: dice quanti record cambierebbero, zero scritture
#   bin/rails 'orthography:fix[20]'           # dry run limitato a 20 record per modello
#   bin/rails 'orthography:fix[,apply]'       # esegue davvero
#   bin/rails 'orthography:fix[20,apply]'     # esegue su 20 record per modello
#
# Le VIRGOLETTE attorno al task non sono decorative: in zsh le parentesi quadre sono un glob, e senza
# virgolette il comando muore con "no matches found" prima ancora di arrivare a Rails.
#
# Default `dry` come `analysis_relabel` e `comment_compaction`, per la stessa ragione: si riscrive il
# testo scritto da qualcun altro. Idempotente — una seconda passata non trova più niente.
namespace :orthography do
  desc "Corregge gli accenti nei testi già salvati (modi: dry|apply, default dry)"
  task :fix, [ :limit, :mode ] => :environment do |_task, args|
    mode = args[:mode].presence || "dry"
    abort "Modo sconosciuto: #{mode} (attesi: dry, apply)" unless %w[dry apply].include?(mode)

    result = Text::BackfillOrthography.call(dry_run: mode == "dry", limit: args[:limit].presence&.to_i)
    verb = mode == "dry" ? "da correggere" : "corretti"

    result.value.each do |model, counts|
      puts format("%-24s %5d guardati, %4d %s", model, counts[:scanned], counts[:corrected], verb)
    end
    puts "DRY RUN: nessuna scrittura. Rilancia con [,apply] per correggere davvero." if mode == "dry"
  end
end
