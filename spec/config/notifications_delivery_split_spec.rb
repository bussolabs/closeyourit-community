# frozen_string_literal: true

require "rails_helper"

# CYRA-744 — avvisi, chat, vault, ticket e credenziali di ingest avevano ciascuno il proprio modo di
# mandare una notifica in app, per email e su Telegram: tredici file della stessa forma, che
# differivano per tre righe su settanta. La correzione di CYRA-672 sullo stato «inviata» è stata
# scritta cinque volte, e cinque volte il commento che la spiega: una correzione sola diventava
# cinque occasioni di dimenticarne una.
#
# Qui si guarda il SORGENTE, non il comportamento: che la consegna viva in un punto solo, che ogni
# dominio abbia un solo punto d'ingresso e che nessuno si sia ripreso in casa la creazione della
# riga, il broadcast del centro notifiche o l'invio su Telegram. Il comportamento lo tengono le
# prove dei domini (spec/services/**/deliver/*_spec.rb), che sono rimaste quelle di prima.
RSpec.describe "La consegna delle notifiche vive in un punto solo", type: :model do
  let(:motore) { Rails.root.join("app/services/notifications") }

  # I sorgenti Ruby dell'applicazione, meno il motore: è lì che non deve tornare nulla.
  def sorgenti_fuori_dal_motore
    Rails.root.glob("app/**/*.rb").reject { |file| file.to_s.start_with?(motore.to_s) }
  end

  # Solo le righe di CODICE: un commento che NOMINA la consegna è memoria utile e resta dov'è;
  # quello che non deve tornare fuori è l'effetto scritto di nuovo.
  def codice(file)
    file.readlines.reject { |riga| riga.strip.start_with?("#") }.join
  end

  def file_che_contengono(frammento)
    sorgenti_fuori_dal_motore.select { |file| codice(file).include?(frammento) }
      .map { |file| file.relative_path_from(Rails.root).to_s }
  end

  it "il motore comune espone i quattro canali" do
    expect(Notifications::Deliver).to respond_to(:in_app, :email, :telegram, :webhook)
  end

  it "la riga della notifica nasce soltanto nel motore" do
    fuori = file_che_contengono("Alerting::Notification.new(")

    expect(fuori).to be_empty,
                     "#{fuori.join(', ')} costruisce la riga di una notifica: quel pezzo è " \
                     "Notifications::Deliver, e il dominio gli passa soltanto il proprio payload."
  end

  it "il centro notifiche è aggiornato soltanto dal motore" do
    fuori = file_che_contengono("alerting_notification_badge")

    expect(fuori).to be_empty,
                     "#{fuori.join(', ')} rifà il broadcast della campanella: lo fa già il motore, " \
                     "una volta per tutti i domini."
  end

  # Chi altro può parlare col bot senza consegnare una notifica: il bot stesso, che risponde ai
  # comandi di chi gli scrive, e il digest, che manda il RIASSUNTO di notifiche già scritte. Nessuno
  # dei due ha una riga da segnare inviata, quindi nessuno dei due passa di qui.
  it "il bot Telegram è chiamato soltanto dal motore, dal bot stesso e dal digest" do
    fuori = file_che_contengono("Telegram::Send.call")
              .grep_v(%r{\Aapp/services/telegram/})
              .grep_v(%r{\Aapp/jobs/notifications/digest_job\.rb\z})

    expect(fuori).to be_empty,
                     "#{fuori.join(', ')} manda il messaggio da sé: l'esito dell'invio decide lo " \
                     "stato della riga (CYRA-672) e quella decisione sta in un punto solo."
  end

  # Un punto d'ingresso per dominio, coi canali come metodi. Le classi per-canale (Deliver::InApp,
  # Deliver::Email, Deliver::Telegram) erano la forma ricopiata cinque volte: se un file così
  # ricompare, la duplicazione è tornata.
  {
    "Alerting::Deliver" => "app/services/alerting/deliver",
    "Chat::Notifications::Deliver" => "app/services/chat/notifications/deliver",
    "Secrets::Notifications::Deliver" => "app/services/secrets/notifications/deliver",
    "Ticketing::Notifications::Deliver" => "app/services/ticketing/notifications/deliver",
    "Projects::Tokens::Notifications::Deliver" => "app/services/projects/tokens/notifications/deliver"
  }.each do |nome, percorso|
    it "#{nome} è un punto d'ingresso solo, coi canali come metodi" do
      punto_ingresso = Rails.root.join("#{percorso}.rb")
      per_canale = Rails.root.glob("#{percorso}/{in_app,email,telegram}.rb")

      expect(punto_ingresso).to exist
      expect(nome.constantize).to respond_to(:in_app, :email, :telegram)
      expect(per_canale).to be_empty,
                            "#{per_canale.join(', ')}: i canali sono metodi del motore, non una " \
                            "classe per canale ricopiata in ogni dominio."
    end
  end

  # Il tetto della Definition of Done, misurato su ogni punto d'ingresso: dentro c'è il payload del
  # dominio — chi è il destinatario, cosa legge, dove clicca — e nient'altro. Sopra questa misura è
  # rientrata la consegna.
  it "ogni punto d'ingresso di dominio dichiara il payload e basta" do
    tetto = 90
    measurements = Rails.root.glob("app/services/{alerting,chat/notifications,secrets/notifications,ticketing/notifications,projects/tokens/notifications}/deliver.rb")
                  .to_h { |file| [ file.relative_path_from(Rails.root).to_s, file.readlines.size ] }

    sforati = measurements.select { |_, righe| righe > tetto }

    expect(sforati).to be_empty,
                       "#{sforati.map { |file, righe| "#{file} misura #{righe} righe" }.join(', ')} " \
                       "(tetto #{tetto}): quello che è cresciuto è consegna, e la consegna sta nel motore."
  end
end
