# frozen_string_literal: true

module Integrations
  # La credenziale con cui UN'organizzazione usa UN servizio esterno (CYRA-544).
  #
  # Gemella di `Alerting::Channel#webhook_secret`, che fa già la stessa cosa: credenziale di un
  # servizio esterno, per-organizzazione, cifrata in colonna, letta a runtime. Cifratura
  # non-deterministica come il vault — non si cerca mai per valore, quindi il determinismo non serve
  # e non lo si paga.
  #
  # Il valore non esce MAI di qui se non attraverso `Integrations::Resolve`: niente serializer, niente
  # `reveal`, niente comando CLI. Chi collega la chiave la incolla e non la rilegge più: si sostituisce.
  # È una scelta, non una dimenticanza — una chiave che si può rileggere è una chiave che si può
  # esfiltrare da una schermata, e qui non serve a nessuno rileggerla.
  class Credential < ApplicationRecord
    self.table_name = "integrations_credentials"

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :integration_credentials
    belongs_to :connected_by, class_name: "Accounts::Account", optional: true

    encrypts :api_key

    # Una credenziale non cambia padrone né servizio: si crea e si sostituisce. Senza questo, un
    # `update(organization_id: …)` sposterebbe la chiave di un'organizzazione dentro un'altra, che è
    # il modo più diretto di consegnare una credenziale a chi non deve averla. Stessa convenzione dei
    # modelli `Secrets::`.
    attr_readonly :organization_id, :provider

    normalizes :api_key, with: ->(value) { value.to_s.strip }

    validates :provider, presence: true, inclusion: { in: ->(_) { Integrations::Providers.keys } },
                         uniqueness: { scope: :organization_id }
    validates :api_key, presence: true

    scope :for_provider, ->(provider) { where(provider: provider.to_s) }
    scope :verified, -> { where.not(verified_at: nil).where(verification_error: nil) }

    # Sostituire la chiave azzera l'esito della prova: quell'esito parlava della chiave PRECEDENTE.
    # Senza, una chiave appena incollata erediterebbe il «verificata due giorni fa» della vecchia, e
    # la pagina mostrerebbe verde una credenziale che nessuno ha mai provato — cioè esattamente la
    # bugia che questa lavorazione esiste per togliere di mezzo.
    before_save :forget_verification, if: :api_key_changed?

    # Il servizio del registro, o nil se quel fornitore non c'è più: una credenziale rimasta di un
    # servizio ritirato non deve far esplodere la pagina che la elenca.
    def provider_definition = Integrations::Providers.find(provider)

    # L'ultima prova è andata male? Non è la stessa cosa di «mai provata»: una chiave appena
    # incollata e non ancora verificata non è una chiave rotta.
    def broken? = verification_error.present?
    def verified? = verified_at.present? && verification_error.blank?

    # Il plaintext non finisce mai in un log, in un backtrace o in una console. `inspect` di
    # ActiveRecord stampa gli attributi, e su un attributo cifrato stamperebbe il ciphertext — che
    # non è il plaintext ma è comunque materiale che non ha ragione di comparire in un log.
    def inspect
      "#<#{self.class.name} id: #{id.inspect} organization_id: #{organization_id.inspect} " \
        "provider: #{provider.inspect} verified_at: #{verified_at.inspect}>"
    end

    private

    def forget_verification
      # Se chi salva sta scrivendo anche un esito nuovo, quello vince: è la prova della chiave nuova,
      # fatta nello stesso passaggio. Azzerarlo qui la butterebbe via.
      return if verified_at_changed? || verification_error_changed?

      self.verified_at = nil
      self.verification_error = nil
    end
  end
end
