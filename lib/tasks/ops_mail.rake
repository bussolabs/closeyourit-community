# frozen_string_literal: true

# Diagnostica della spedizione email (CYRA-233). Guscio sottile: la logica sta in Ops::MailSenderCheck e
# Ops::SendTestEmail, che hanno le loro spec — qui c'è solo la stampa a schermo.
#
#   bin/rails ops:mail_status                          → il mittente è abilitato a spedire?
#   bin/rails "ops:mail_test[persona@esempio.it]"      → manda davvero un'email di prova
#
# In produzione girano dal container: kamal app exec 'bin/rails ops:mail_status'
namespace :ops do
  desc "Verifica se il mittente configurato è abilitato a spedire (nessuna email inviata)"
  task mail_status: :environment do
    result = Ops::MailSenderCheck.call

    puts "Mittente : #{result.from}"
    puts "Dominio  : #{result.domain || "-"}"
    puts "Stato    : #{result.status}"
    puts "Dettaglio: #{result.detail}" if result.detail.present?
    puts result.deliverable? ? "\n✅ Il mittente può spedire." : "\n❌ Da questo mittente NON parte nessuna email."

    exit(1) unless result.deliverable?
  end

  desc "Manda un'email di prova al destinatario indicato (spedizione REALE)"
  task :mail_test, [ :to ] => :environment do |_task, args|
    result = Ops::SendTestEmail.call(to: args[:to].to_s)

    if result.ok?
      puts "✅ Email di prova spedita a #{result.value[:to]} da #{result.value[:from]}."
      puts "   Controlla la casella (e la posta indesiderata): se non arriva, la spedizione è rifiutata a valle."
    else
      puts "❌ #{result.error.message} (#{result.error.code})"
      exit(1)
    end
  end
end
