# frozen_string_literal: true

# Il giorno del passaggio (CYRA-549): le chiavi dei servizi esterni smettono di essere una sola,
# quella di chi gestisce l'installazione, e diventano le credenziali di ciascuna organizzazione.
#
# Questa migrazione fa la sola parte che non si può chiedere a nessuno di rifare a mano: mette le
# chiavi che oggi stanno nell'ambiente sull'organizzazione dell'operatore, così chi le ha pagate
# finora continua ad avere i servizi accesi senza dover ricollegare niente. Tutte le altre partono
# non collegate — è il dato onesto, e il motivo per cui questa lavorazione esiste.
#
# Richiede AR_ENCRYPTION_* (la colonna della chiave è cifrata, come il backfill di
# `alerting_channels`): al deploy quelle arrivano dal canale di bootstrap gestito dall'operatore.
#
# Se l'organizzazione dell'operatore non è riconoscibile — nessun superadmin proprietario, o più di
# uno — NON indovina e non scrive niente: la si indica a mano con
# `bin/rails "integrations:adopt_system_keys[<slug>]"`, che fa esattamente lo stesso lavoro.
class AdoptSystemIntegrationKeys < ActiveRecord::Migration[8.1]
  def up
    Integrations::Credential.reset_column_information
    organization = Integrations::Operator.organization

    if organization.nil?
      say "Nessuna organizzazione dell'operatore riconoscibile: nessuna chiave adottata. " \
          'Eseguire a mano: bin/rails "integrations:adopt_system_keys[<slug>]"'
      return
    end

    adopted = Integrations::AdoptSystemKeys.call(organization: organization).value
    say "Chiavi adottate da #{organization.slug}: #{adopted.presence&.join(', ') || 'nessuna'}"
  end

  # Nessun ritorno indietro, e non è una dimenticanza: le chiavi restano comunque nell'ambiente,
  # quindi il rollback non recupera niente che sia andato perso. Cancellare le credenziali, invece,
  # butterebbe via anche quelle che nel frattempo qualcuno ha sostituito con le proprie — un danno
  # vero al posto di un ripristino.
  def down
    say "Niente da annullare: le credenziali adottate si tolgono dalla pagina Integrazioni."
  end
end
