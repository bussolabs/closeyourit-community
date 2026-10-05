# frozen_string_literal: true

module Integrations
  # Ri-prova ogni giorno tutte le chiavi collegate, e scrive com'è andata (CYRA-549).
  #
  # PERCHÉ ESISTE. Una chiave si prova nel momento in cui la si incolla, e poi mai più. Fra quel
  # momento e il primo utilizzo passano settimane, e in mezzo la chiave può essere revocata,
  # scaduta, ristretta o il servizio spento nella console del fornitore. Senza questo giro il guasto
  # si manifesta come una funzione che tace: nessun errore, nessuna riga rossa, nessuno che se ne
  # accorga finché non è una persona a scrivere che «l'assistente non risponde più da un po'». È il
  # guasto tipico di questo prodotto, ed è già costato un giorno e mezzo di embedding spenti.
  #
  # L'esito si SCRIVE SEMPRE, anche quando è «fornitore irraggiungibile». La colonna dice cos'è
  # successo all'ultima prova, e nasconderne una parte perché «forse era solo la rete» è il modo in
  # cui si costruisce una pagina che rassicura mentendo. Lo slug distingue i casi
  # (`Integrations::Verify`), quindi chi legge sa se ricopiare la chiave o riprovare più tardi.
  #
  # UN SOLO job che scorre, senza fan-out per credenziale: la prova è una chiamata corta (una GET a
  # Google) e un job per credenziale aggiungerebbe righe in coda senza far finire prima un solo
  # controllo.
  #
  # Corsia `batch` e non `maintenance` (CYRA-714): la singola prova è corta, ma il giro attraversa la
  # tabella intera e fa una chiamata di rete PER RIGA — la sua durata cresce col numero di chiavi
  # collegate, cioè con le organizzazioni. È esattamente la forma dei lavori lunghi, e sulla corsia
  # dei controlli metterebbe in fila i giri al minuto man mano che il prodotto cresce.
  #
  # La prova di UNA credenziale vive in `Integrations::CheckCredential` (CYRA-712): un solo modo di
  # provare e di scrivere l'esito, qualunque sia chi lo chiede.
  class VerifyJob < ApplicationJob
    queue_as :batch

    def perform
      Integrations::Credential.find_each do |credential|
        Integrations::CheckCredential.call(credential: credential)
      end
    end
  end
end
