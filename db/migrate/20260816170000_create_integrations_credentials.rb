# frozen_string_literal: true

# Le credenziali che un'organizzazione porta per i servizi esterni (CYRA-544).
#
# NON è il Vault. `Secrets::` custodisce i segreti delle applicazioni DEL CLIENTE: si delegano ai
# progetti e si sincronizzano sui GitHub Actions. Queste sono chiavi che CloseYourIt usa PER SÉ, per
# conto di quell'organizzazione. Tenerle nella stessa tabella significherebbe due significati con la
# stessa faccia, il rischio di esportarne una su GitHub, e un nome rinominabile a mano che spegne una
# funzione senza spiegare perché.
#
# La forma è quella di `alerting_channels`, che fa già esattamente questo: credenziale di un servizio
# esterno, per-organizzazione, cifrata in colonna, letta a runtime.
#
# NESSUN AMBIENTE: l'installazione È l'ambiente, e un account Google ha una chiave sola. Il Vault ha
# gli ambienti perché distribuisce valori alle app del cliente, che ne hanno più di uno.
class CreateIntegrationsCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :integrations_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.timestamps

      # Chi l'ha collegata. `connected_by` e non `created_by` perché è quello che la pagina mostra:
      # non «chi ha creato la riga», ma chi ha messo la chiave e a chi chiedere se non funziona.
      t.references :connected_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false, comment: "Chiave del registro Integrations::Providers"
      # Cifrata at-rest con AR::Encryption non-deterministica, come i valori del vault: non si
      # interroga mai per valore, quindi non serve il determinismo e non lo si paga.
      t.text :api_key, null: false
      # Esito dell'ultima prova. `verification_error` porta un CODICE nostro, mai il messaggio libero
      # del fornitore: quello può contenere pezzi della richiesta, e una chiave finita in un campo di
      # testo è una chiave in chiaro.
      t.datetime :verified_at
      t.string :verification_error

      # Una credenziale per servizio per organizzazione: sostituire, non accumulare.
      t.index %i[organization_id provider], unique: true
    end
  end
end
