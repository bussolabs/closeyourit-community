# frozen_string_literal: true

# CYRA-750 — `db/schema.rb` descrive la tabella padre ma non le sue fette (vedi
# config/initializers/partitions.rb): un database appena creato o ricaricato è un contenitore senza
# scomparti, e la prima scrittura fallirebbe con «nessuna fetta per questa riga». Questi agganci
# rimettono le fette subito dopo il caricamento dello schema, così nessuno deve ricordarsene.
#
# Solo i comandi che lavorano sul database dell'ambiente CORRENTE: `db:test:prepare` prepara un
# database diverso da quello a cui l'applicazione è connessa, quindi lì il posto giusto è
# spec/rails_helper.rb, che gira già connesso alle prove.
namespace :db do
  namespace :partitions do
    desc "Crea le fette mancanti delle tabelle di telemetria (idempotente)"
    task ensure: :environment do
      created = Ops::Partitions::Ensure.call
      puts created.any? ? "fette create: #{created.join(', ')}" : "fette già a posto"
    end
  end
end

%w[db:schema:load db:prepare].each do |task_name|
  Rake::Task[task_name].enhance { Rake::Task["db:partitions:ensure"].invoke }
end
