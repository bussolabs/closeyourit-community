# frozen_string_literal: true

# Il passaggio dalla chiave unica alle chiavi di ciascuno, a mano (CYRA-549).
#
#   bin/rails integrations:adopt_system_keys              # l'organizzazione dell'operatore, se riconoscibile
#   bin/rails "integrations:adopt_system_keys[acme]"      # quella indicata, per slug o identificativo
#
# Lo stesso lavoro che fa la migrazione `AdoptSystemIntegrationKeys`, disponibile a comando. Serve
# perché la migrazione, quando l'organizzazione dell'operatore non è riconoscibile — nessun
# superadmin proprietario, oppure più di uno — si rifiuta di indovinare e non scrive niente: una
# migrazione si esegue una volta sola e non si può ri-lanciare dopo aver capito quale fosse.
#
# Prende le chiavi dall'ambiente in cui gira, e le scrive SOLO sull'organizzazione indicata. Non
# tocca una credenziale già collegata: rilanciarlo è innocuo.
namespace :integrations do
  desc "Adotta le chiavi dei servizi esterni presenti nell'ambiente su UNA organizzazione (slug o id)"
  task :adopt_system_keys, [ :organization ] => :environment do |_task, args|
    wanted = args[:organization].to_s.strip
    # L'identificativo si cerca SOLO se ha la forma di un identificativo: la colonna è di tipo uuid e
    # PostgreSQL, davanti a uno slug, non risponde «nessun risultato» — solleva. Chi ha sbagliato a
    # scrivere il nome deve leggere «organizzazione non trovata», non una riga di errore del database.
    organization = if wanted.present?
      Organizations::Organization.find_by(slug: wanted) ||
        (Organizations::Organization.find_by(id: wanted) if wanted.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/))
    else
      Integrations::Operator.organization
    end

    if organization.nil?
      abort 'Organizzazione non trovata. Indicarla: bin/rails "integrations:adopt_system_keys[<slug>]"'
    end

    adopted = Integrations::AdoptSystemKeys.call(organization: organization).value

    if adopted.empty?
      puts "Nessuna chiave da adottare per #{organization.slug}: " \
           "o non ce n'è nessuna nell'ambiente, o sono già collegate."
    else
      puts "Chiavi adottate da #{organization.slug}: #{adopted.join(', ')}."
      puts "Nessun'altra organizzazione è stata toccata."
    end
  end
end
