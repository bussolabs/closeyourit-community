# frozen_string_literal: true

# CYRA-589 — Il controllo che dice subito quando due migration si sono prese lo stesso numero.
#
#   bin/rails db:migrations:collisions                        # confronta con origin/main
#   MIGRATION_BASE_REF=origin/release bin/rails db:migrations:collisions
#
# Nessun `=> :environment`: il controllo guarda file e git, non ha niente da chiedere al database.
# Così gira anche dove il database non c'è — che è esattamente il caso del giro automatico.
#
# Confronta con l'origin/main che hai in casa: se è vecchio di giorni può non vedere una collisione
# nata nel frattempo (`git fetch origin main` prima, quando conta). Non lo fa da solo di proposito —
# un controllo non tocca la rete alle spalle di chi lo lancia. Nel giro automatico il problema non
# esiste: il checkout è appena stato scaricato.
require Rails.root.join("lib/migration_version_guard").to_s unless defined?(MigrationVersionGuard)

namespace :db do
  namespace :migrations do
    desc "Ferma il lavoro se una migration porta una versione già presa sul ramo principale"
    task :collisions do
      base_ref = ENV.fetch("MIGRATION_BASE_REF", MigrationVersionGuard::DEFAULT_BASE_REF)
      verdict = MigrationVersionGuard.call(root: Rails.root, base_ref: base_ref)

      unless verdict.comparable?
        # Sul computer di chi lavora il riferimento può mancare per mille ragioni innocenti (clone
        # parziale, remoto non aggiornato): avviso e lascio proseguire. Nel giro automatico no: un
        # gate che non ha potuto confrontare e tace è peggio di nessun gate, perché fa credere che
        # qualcuno abbia guardato.
        abort verdict.message if ENV["CI"].present?

        warn verdict.message
        next
      end

      abort verdict.message unless verdict.clean?

      puts verdict.message
    end
  end
end
