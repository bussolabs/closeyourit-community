# frozen_string_literal: true

# Regole di avviso di default sulle organizzazioni GIÀ esistenti (CYRA-846). Alerting::Rules::
# InstallDefaults gira solo a creazione dell'organizzazione (Organizations::Provision): un tipo di
# avviso aggiunto dopo nasce senza regola, e Alerting::Evaluate lo genera e lo butta via — il
# silenzio che quel tipo di avviso doveva rompere. Idempotente: crea solo ciò che manca.
#
#   bin/rails alerting:install_defaults
#
# In produzione gira dal container: kamal app exec 'bin/rails alerting:install_defaults'
namespace :alerting do
  desc "Installa le regole di avviso di default mancanti su tutte le organizzazioni (idempotente)"
  task install_defaults: :environment do
    created = 0
    Organizations::Organization.find_each do |organization|
      before = Alerting::Rule.where(organization_id: organization.id).count
      Alerting::Rules::InstallDefaults.call(organization: organization)
      after = Alerting::Rule.where(organization_id: organization.id).count
      added = after - before
      created += added
      puts "#{organization.name}: #{added} regole aggiunte" if added.positive?
    end

    puts created.zero? ? "Nessuna regola mancante." : "\n✅ #{created} regole di default aggiunte."
  end
end
